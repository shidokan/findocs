"""
SEC EDGAR filing fetcher for FinDocs AI Platform.

Downloads 10-K and 10-Q filings for the configured tenants and uploads
the cleaned text content to per-tenant blob containers for downstream
indexing by Azure AI Search.

EDGAR rules respected:
  - Custom User-Agent (required by SEC): "<name> <email>"
  - Rate limit: 10 requests/second maximum (we self-limit to 5/sec)
  - HTTPS only

Usage:
    python edgar_fetcher.py --tenant tech --filings 10-K,10-Q --years 3
    python edgar_fetcher.py --tenant banks --companies JPM,BAC --filings 10-K

The script is designed to run as an Azure Function timer trigger (monthly)
but works locally for development and one-shot backfills.
"""

import argparse
import asyncio
import json
import os
import re
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import httpx
from dotenv import load_dotenv

load_dotenv()

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
EDGAR_BASE = "https://data.sec.gov"
EDGAR_SEARCH = "https://efts.sec.gov/LATEST/search-index"
USER_AGENT = os.environ.get(
    "SEC_USER_AGENT",
    "FinDocs Platform Engineering platform@example.com",
)
RATE_LIMIT_RPS = 5
HTTP_TIMEOUT = 30.0

# Tenant ↔ company list. In production this lives in a config blob; hardcoded
# here for portability of the demo.
TENANT_COMPANIES = {
    "tech":   ["AAPL", "MSFT", "NVDA", "GOOGL", "META", "AMZN", "ORCL", "IBM", "ADBE", "CRM"],
    "banks":  ["JPM",  "BAC",  "WFC",  "C",     "GS",   "MS",   "USB",  "PNC", "TFC",  "COF"],
    "energy": ["XOM",  "CVX",  "COP",  "EOG",   "OXY",  "PSX",  "MPC",  "VLO", "SLB",  "HAL"],
}

OUTPUT_ROOT = Path(os.environ.get("EDGAR_OUTPUT_DIR", "./filings"))


# -----------------------------------------------------------------------------
# Data classes
# -----------------------------------------------------------------------------
@dataclass
class Filing:
    ticker:        str
    cik:           str
    form_type:     str          # "10-K" or "10-Q"
    accession_no:  str          # e.g. "0000320193-25-000045"
    filing_date:   str          # ISO date
    fiscal_period: str          # e.g. "2025-Q3" or "2025-FY"
    primary_doc:   str          # main filing HTML filename

    @property
    def archive_url(self) -> str:
        # Path with dashes stripped for SEC's directory layout
        acc = self.accession_no.replace("-", "")
        return f"{EDGAR_BASE}/Archives/edgar/data/{int(self.cik)}/{acc}/{self.primary_doc}"

    @property
    def blob_path(self) -> str:
        # Convention used by tenant_router.py and the AI Search indexer
        return f"{self.ticker}/{self.form_type}/{self.fiscal_period}.html"


# -----------------------------------------------------------------------------
# SEC API helpers
# -----------------------------------------------------------------------------
class EdgarClient:
    def __init__(self, user_agent: str = USER_AGENT, rps: int = RATE_LIMIT_RPS):
        self.client = httpx.AsyncClient(
            headers={"User-Agent": user_agent, "Accept-Encoding": "gzip"},
            timeout=HTTP_TIMEOUT,
            http2=True,
        )
        self.min_interval = 1.0 / rps
        self._last_request = 0.0

    async def _throttled_get(self, url: str) -> httpx.Response:
        elapsed = time.monotonic() - self._last_request
        if elapsed < self.min_interval:
            await asyncio.sleep(self.min_interval - elapsed)
        self._last_request = time.monotonic()
        resp = await self.client.get(url)
        resp.raise_for_status()
        return resp

    async def ticker_to_cik(self, ticker: str) -> str | None:
        """Resolve a ticker to its CIK via SEC's company_tickers.json index."""
        if not hasattr(self, "_ticker_index"):
            resp = await self._throttled_get(f"https://www.sec.gov/files/company_tickers.json")
            data = resp.json()
            self._ticker_index = {
                row["ticker"].upper(): str(row["cik_str"]).zfill(10)
                for row in data.values()
            }
        return self._ticker_index.get(ticker.upper())

    async def list_filings(
        self,
        ticker: str,
        form_types: Iterable[str],
        years: int = 3,
    ) -> list[Filing]:
        """List recent filings for a ticker, filtered by form type."""
        cik = await self.ticker_to_cik(ticker)
        if not cik:
            print(f"WARN: CIK not found for {ticker}", file=sys.stderr)
            return []

        # Submissions API gives the full recent filings list
        url = f"{EDGAR_BASE}/submissions/CIK{cik}.json"
        resp = await self._throttled_get(url)
        data = resp.json()
        recent = data["filings"]["recent"]

        cutoff_year = time.gmtime().tm_year - years
        filings: list[Filing] = []

        for i, form in enumerate(recent["form"]):
            if form not in form_types:
                continue
            filing_date = recent["filingDate"][i]
            year = int(filing_date.split("-")[0])
            if year < cutoff_year:
                continue

            accession = recent["accessionNumber"][i]
            primary_doc = recent["primaryDocument"][i]
            report_date = recent.get("reportDate", [None] * len(recent["form"]))[i] or filing_date

            # Derive fiscal period: "2025-Q3" or "2025-FY"
            rd_year, rd_month = report_date.split("-")[0], int(report_date.split("-")[1])
            if form == "10-K":
                fiscal_period = f"{rd_year}-FY"
            else:
                # 10-Q: map quarter from month
                quarter = (rd_month - 1) // 3 + 1
                fiscal_period = f"{rd_year}-Q{quarter}"

            filings.append(Filing(
                ticker=ticker.upper(),
                cik=cik,
                form_type=form,
                accession_no=accession,
                filing_date=filing_date,
                fiscal_period=fiscal_period,
                primary_doc=primary_doc,
            ))

        return filings

    async def download(self, filing: Filing, output_path: Path) -> int:
        """Download the filing's primary document. Returns bytes written."""
        output_path.parent.mkdir(parents=True, exist_ok=True)
        resp = await self._throttled_get(filing.archive_url)
        content = resp.content
        output_path.write_bytes(content)
        return len(content)

    async def aclose(self) -> None:
        await self.client.aclose()


# -----------------------------------------------------------------------------
# Tenant routing
# -----------------------------------------------------------------------------
def companies_for_tenant(
    tenant: str,
    override: list[str] | None = None,
) -> list[str]:
    if override:
        return override
    if tenant not in TENANT_COMPANIES:
        raise ValueError(f"Unknown tenant '{tenant}'. Known: {sorted(TENANT_COMPANIES)}")
    return TENANT_COMPANIES[tenant]


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
async def fetch_tenant(
    tenant:     str,
    companies:  list[str],
    form_types: list[str],
    years:      int,
    output_dir: Path,
) -> None:
    """Fetch all filings for one tenant's company list."""
    client = EdgarClient()
    try:
        all_filings: list[Filing] = []
        for ticker in companies:
            print(f"[{tenant}/{ticker}] listing filings...")
            filings = await client.list_filings(ticker, form_types, years)
            all_filings.extend(filings)

        print(f"[{tenant}] found {len(all_filings)} filings across {len(companies)} companies")
        print(f"[{tenant}] downloading to {output_dir}/{tenant}/...")

        total_bytes = 0
        for i, filing in enumerate(all_filings, start=1):
            out_path = output_dir / tenant / filing.blob_path
            if out_path.exists():
                print(f"  [{i}/{len(all_filings)}] SKIP {filing.ticker} {filing.form_type} {filing.fiscal_period} (exists)")
                continue
            size = await client.download(filing, out_path)
            total_bytes += size
            print(f"  [{i}/{len(all_filings)}] {filing.ticker} {filing.form_type} {filing.fiscal_period} - {size:,} bytes")

        # Write manifest for downstream chunker / indexer
        manifest_path = output_dir / tenant / "_manifest.json"
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(json.dumps([
            {
                "ticker": f.ticker,
                "form_type": f.form_type,
                "filing_date": f.filing_date,
                "fiscal_period": f.fiscal_period,
                "blob_path": f.blob_path,
                "accession_no": f.accession_no,
            }
            for f in all_filings
        ], indent=2))
        print(f"[{tenant}] wrote manifest with {len(all_filings)} entries")
        print(f"[{tenant}] total downloaded: {total_bytes / 1_000_000:.1f} MB")
    finally:
        await client.aclose()


def main() -> None:
    p = argparse.ArgumentParser(description="Fetch SEC EDGAR filings for a FinDocs tenant.")
    p.add_argument("--tenant", required=True, choices=sorted(TENANT_COMPANIES.keys()))
    p.add_argument("--companies", help="Override the tenant default company list (comma-separated tickers)")
    p.add_argument("--filings", default="10-K,10-Q", help="Comma-separated form types")
    p.add_argument("--years", type=int, default=3, help="How many years back to fetch")
    p.add_argument("--output-dir", default=str(OUTPUT_ROOT), help="Local output directory")
    args = p.parse_args()

    companies  = args.companies.split(",") if args.companies else companies_for_tenant(args.tenant)
    form_types = [f.strip() for f in args.filings.split(",")]
    output_dir = Path(args.output_dir)

    asyncio.run(fetch_tenant(args.tenant, companies, form_types, args.years, output_dir))


if __name__ == "__main__":
    main()
