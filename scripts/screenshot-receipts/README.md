# Scrubbed receipts (for screenshots)

13 receipts with private data replaced. Safe to use in screenshots.

## Substitutions applied (consistent across all files)

| Original                     | Replacement          |
|------------------------------|----------------------|
| N491JL (tail)                | N552RG               |
| JYNAIR / JYNAIR LLC          | SKYVANE / SKYVANE LLC|
| JLW AVIATION                 | SUMMIT AVIATION      |
| KIM MILLER                   | KIM PORTER           |
| Carolynn Loacker (surname)   | Carolynn Hollis      |
| Customer # 533963 (Atlantic) | 548210               |
| Customer # 3954686 (WFS)     | 3948210              |
| Card last-4 0121             | 0198                 |
| Alliance Card **9011         | **9044               |
| PO Box 25407, 97298-0407     | PO Box 41190, 97210-1190 |

Everything else (vendor names, amounts, dates, FBO addresses, invoice/auth
numbers) left untouched intentionally.

## How they were edited

- **12 files** (7× Atlantic `InvoiceReceipt*`, `Invoice_JLW_AVIATION`,
  4× `Unknown-*` World Fuel Services) had a real text layer — edited by
  deleting the original glyphs and re-typesetting the replacements. Text layer
  verified clean (no private tokens extractable).
- **`Doc - Feb 5 2026 - 10-05.pdf`** (Million Air) is an image scan with no text
  layer — edited by covering the private text with matched-background patches
  and overlaying the replacements.

## Skipped (per your call)

Three photographed thermal receipts were left out — they're photos of curled
paper with no text layer, so a clean swap wasn't possible without visible
tampering:

- `Receipt - Feb 18 2026 - 12-53.pdf` (US Aviation)
- `Doc - Feb 5 2026 - 15-44.pdf` (Avflight Milwaukee)
- `Doc - May 1 2026 - 12-26.pdf` (Avflight Salina)

Originals remain in `../fake-receipts/`.
