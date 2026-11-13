# Reproducibility and methodological audit — Makay vs Isalo GBIF comparison

**Audit date:** 2026-11-13 · **Auditor:** Posit Assistant (automated audit, all steps re-executed from source data) · **Scope:** `makay_isalo_report.qmd` / `.html`, `results_interpretation.md`, `R/compare_makay_isalo.R`, `R/convert_gbif_madagascar_to_parquet.R`, GBIF parquet dataset, WDPA geodatabase, `outputs/`.

---

## 1. Executive summary

| # | Finding | Status |
|---|---------|--------|
| 1 | The parquet conversion silently dropped **300,486 of 3,635,415** GBIF records (~8%) and injected **70,239,134 all-NA phantom rows** | **Confirmed, corrected** |
| 2 | The "Madagascar present records = 73,144,444" figure in the HTML was phantom-row inflation; the true figure is **3,635,415** (verified against the GBIF API) | **Confirmed, corrected** |
| 3 | `species_label = coalesce(species, scientificName)` counted genus/family/order-level identifications as species | **Confirmed, corrected** (accepted species now counted via GBIF backbone `speciesKey`) |
| 4 | The Markdown note's figures (2,749 Isalo / 1,293 Makay species) could not be reproduced from any preserved artifact; all preserved artifacts agree on 2,768 / 1,274 for the legacy method | **Unsourced, superseded** |
| 5 | Areas: three different conventions were in play (866/868.7/865.7 km² Isalo; 4,056/4,067/4,052 km² Makay) | **Explained**; EPSG:6933 (= WDPA `GIS_AREA`) adopted |
| 6 | Polygons are WDPA site polygons (Isalo NP site 2312, designated; Makay AP site 555790177, *proposed*), not geomorphological massif outlines; one polygon per site, no overlaps, clipping by exact `st_within` verified | **Confirmed** |
| 7 | The Makay/Isalo occurrence-density contrast is robust to dataset exclusion, basis-of-record and uncertainty filters (34×–47×), but reverses for preserved specimens alone (Makay leads) | **Quantified** |
| 8 | For vascular plants the raw species gap nearly closes (Isalo 622 vs Makay 524); the all-taxon gap (1,486 vs 883) is driven by Isalo's molecular bulk-sampling campaigns | **New result** |

## 2. Provenance — verified facts

**GBIF occurrence download** (verified from the GBIF API and the local archive):

- Download key `0000459-260720095953322`, DOI **10.15468/dl.ufwdju**.
- Created 2026-07-20 19:51:06 UTC, completed 22:53:14 UTC; status SUCCEEDED.
- Format `SIMPLE_CSV` (50 columns); predicate `occurrenceStatus = PRESENT` AND `country = MG`.
- `totalRecords = 3,635,415`, `numberDatasets = 2,006`; license CC BY-NC 4.0.
- Local archive `data/0000459-260720095953322.zip` (414.8 MB) contains exactly one CSV (2,152,942,690 bytes); line count 3,635,416 (header + 3,635,415 records) matches the API exactly.

**WDPA spatial data:**

- `WDPA_Jul2026_MDG-shapefile.zip` (WDPA/WDOECM **July 2026** public release; internal gdb file dates 2026-07-16). Two local copies (downloaded 2026-07-20 and 2026-07-22) are **byte-identical** (MD5 `d96a919e7ce1ed8389c9da863f692d8d`).
- File Geodatabase `WDPA_WDOECM_Jul2026_Public_MDG.gdb` (167 polygons, 3 points); `wdpar::wdpa_read()` performs no geometry processing beyond unzipping, so direct GDAL reading reproduces the same polygons. Note: `wdpar::wdpa_fetch()` web-scraping no longer works and has been replaced by a direct read in the updated Quarto report.

**Unverified / unavailable:**

- The exact R/package versions used for the original runs (no git history, no renv lockfile). Session was R 4.5.1 with arrow 22.0.0.1, sf/GEOS 3.13.1, wdpar 1.3.8 at audit time.
- The source of the Markdown note's species figures (see §4) — the intermediate computation that produced them was not preserved.
- IUCN Red List categories are **absent from the SIMPLE_CSV format**; the earlier "red-list comparison" table could never have been informative from this download (a DWCA download would be required).

## 3. Parquet conversion defects (root causes)

**Defect A — phantom rows (73,144,444 "Madagascar records").** The original converter subset each chunk with `chunk$lon_bin == lon_value & chunk$lat_bin == lat_value`. For rows with missing coordinates, `x == NA` returns `NA`, not `FALSE`; and subsetting a data frame with a logical vector containing `NA` returns **all-NA rows**. Consequently: (i) the `__HIVE_DEFAULT_PARTITION__` folder received a full 100,000-row all-NA copy of *every* chunk; (ii) every partition file of a chunk received one phantom row per coordinate-less record of that chunk. Totals measured by file-level scan: 70,239,134 phantom rows + 2,905,310 real rows = 73,144,444. The original report's "share of Madagascar" (0.1%) was therefore meaningless; the corrected share is 60,456 / 3,635,415 = **1.66%**.

**Defect B — silently dropped records.** The GBIF CSV contains **262 records with stray unescaped `"` characters** inside field values (a GBIF writer defect; e.g. an `identifiedBy` field containing a bare `"`; line 1,222,364 of the CSV). No field value contains tabs or line breaks (lines = records + header, verified), but `readr::read_tsv_chunked()` loses quote-scanner synchronisation on these records and silently dropped **300,486 records** (233,893 geo-referenced + 66,593 without coordinates). `arrow`'s parallel CSV reader errors out on the same rows; DuckDB with quoting disabled (`quote = ''`) parses all 3,635,415 records exactly.

**Impact:** the legacy parquet underlay *all* reported numbers. Occurrence counts per area were internally consistent but undercounted (Isalo 49,606 → **53,115**; Makay 6,692 → **7,341**; candidates 222,529 → **235,989**; bbox hits 63,848 → 68,259 and 7,640 → 8,407). The corrected dataset (same partitioning, all 50 columns, no phantoms) now sits at `data/parquet/gbif_madagascar`; the superseded one is archived in `data/parquet/gbif_madagascar.zip` and a copy remains at `data/parquet/gbif_madagascar_legacy_bugged/`. `R/convert_gbif_madagascar_to_parquet.R` has been rewritten (DuckDB-based) and documents both defects.

## 4. Species counting and the 2,749/1,293 discrepancy

**Why the legacy "species" counts were inflated.** `coalesce(species, scientificName)` falls back to the verbatim `scientificName` whenever GBIF's backbone-derived `species` field is empty — i.e. for identifications above species rank and unmatched names. In the legacy clipped data, the most frequent "species" of Isalo were *Diptera* (2,071 records), *Coleoptera* (1,941), *Chironomidae Newman, 1834* (1,859), *Russulaceae Lotsy, 1907* (1,858) — orders and families. The legacy counts therefore mixed true species with higher-rank labels and authorship variants.

**Corrected method.** Accepted species are counted as distinct GBIF backbone **`speciesKey`** values (populated only for identifications at or below species rank; synonyms resolve to the accepted usage at processing time). Verified properties: **no** species-rank record lacks a `speciesKey` (so nothing species-level is lost); `speciesKey`↔`species` agree except six name strings shared by two homotypic backbone keys (keys used throughout); `species` never carries authorship. Records without `speciesKey` (Isalo 35,339 = 66.5% of occurrences; Makay 2,456 = 33.5%) are almost entirely FAMILY/ORDER/GENUS/UNRANKED identifications (rank table in the HTML report) and are counted as occurrences only.

**Treatment summary:** synonyms — resolved automatically by the backbone (`speciesKey` points to the accepted species); unresolved/higher-rank identifications — retained as occurrences, excluded from species counts, reported separately; missing taxonomic fields — occurrences retained where coordinates exist.

**The Markdown figures (2,749 / 1,293).** Eleven counting variants (species-only, scientificName-only, reversed coalesce, genus fallback, whitespace squishing, gbifID and coordinate deduplication, class availability, issue filtering, uncertainty filtering) were tested against the preserved legacy record set (RDS): **none reproduces 2,749/1,293**. The values are internally coherent with the legacy shared/union counts (483/3,559) but imply 19 species moving between areas, which the disjoint polygons cannot produce with unchanged occurrence counts. All preserved artifacts (RDS of 2026-07-21 11:07, CSV outputs, HTML of 2026-07-22) agree on **2,768 / 1,274** (legacy method). Verdict: the Markdown figures come from an unpreserved intermediate run and are **superseded**; they should not be cited. (The Markdown note file was left untouched.)

## 5. Spatial delimitation — verified

| Property | Isalo | Makay |
|---|---|---|
| WDPA site | SITE_ID **2312**, "Isalo", Parc National / National Park | SITE_ID **555790177**, "Makay", Aire Protégée / Protected Area |
| Status | Designated 1962, IUCN II, MNP, State Verified | **Proposed** 2015, IUCN "Not Reported", government-delegated management |
| Reported area (REP_AREA, km²) | 815.4 | 3,690 |
| GIS_AREA / EPSG:6933 (km²) | 866.5295 | 4,056.3651 |
| EPSG:29702 Laborde (km²) — old QMD | 865.67 ("866") | 4,052.42 ("4,052") |
| Geodesic WGS84 (km²) — old script | 868.72 ("869") | 4,067.46 ("4,067") |
| Geometry | 1 polygon, valid, no duplicates | 1 polygon, valid, no duplicates |

- The two polygons **do not overlap** (`st_intersects` = empty); there is exactly one site per area and no point-record duplicates in the WDPA point layer.
- **Equivalent spatial entities?** Both are WDPA site polygons of protected-area entities — the comparison is between equivalent *administrative* units. They are **not** geomorphological delineations of the massifs: for Makay, the WDPA polygon is the boundary of the proposed protected area (which was designed around the massif); Isalo's polygon (866.5 km² GIS) is somewhat larger than its gazetted area (815.4 km²). For a floristic manuscript, Makay's boundary is also legally weaker (proposed status, 2015).
- **Clipping:** occurrences were clipped by exact point-in-polygon (`st_within` on the 4326 geometries after `st_make_valid`), not by bounding box; the bbox stage is a prefilter only. Verified: bbox counts 68,259 (Isalo) / 8,407 (Makay) reduce to 53,115 / 7,341 inside polygons. All bins touched by either bbox are covered by the read (floored bbox bins ⊆ read bins).

## 6. Corrected comparison table (polygon-clipped, accepted species)

| Scope | Area | Area km² | Occurrences | Accepted species | Occ / 100 km² | Species / 100 km² |
|---|---|---|---|---|---|---|
| All taxa | Isalo | 866.5 | 53,115 | 1,486 | 6,130.0 | 171.5 |
| All taxa | Makay | 4,056.4 | 7,341 | 883 | 181.0 | 21.8 |
| Plantae | Isalo | 866.5 | 4,573 | 649 | 527.9 | 74.9 |
| Plantae | Makay | 4,056.4 | 3,845 | 567 | 94.8 | 14.0 |
| Vascular plants | Isalo | 866.5 | 4,454 | 622 | 514.0 | 71.8 |
| Vascular plants | Makay | 4,056.4 | 3,647 | 524 | 89.9 | 12.9 |

Overlap (accepted species): all taxa — Isalo 1,486 / Makay 883 / shared 376 / union 1,993, Jaccard 0.189, Sørensen 0.317; vascular plants — 622 / 524 / shared 172 / union 974, Jaccard 0.177, Sørensen 0.300.

## 7. Sampling and database biases

**Basis of record (corrected data):** Isalo — MATERIAL_SAMPLE 35,102 (66.1%), HUMAN_OBSERVATION 12,977 (24.4%), PRESERVED_SPECIMEN 4,955 (9.3%); Makay — PRESERVED_SPECIMEN 5,995 (81.7%), HUMAN_OBSERVATION 654 (8.9%), MATERIAL_SAMPLE 645 (8.8%). The contrast reproduces the original finding and is explained by datasets: Isalo's material samples are molecular/bulk campaigns (iBOL barcoding 15,641 records = 29%; CO1 amplicon sequence variants of bulk arthropods 8,351 = 16%; Global soil organisms 8,096 = 15%; eBird EOD 8,332 = 16%; iNaturalist 3,892 = 7%), while Makay is dominated by Tropicos herbarium specimens (3,339 = 45%) and AntWeb (1,940 = 26%). Within vascular plants, ~90% of Makay's records are Tropicos herbarium specimens; Isalo's are more mixed (iNaturalist 34%, Tropicos 29%, MNHN 13%).

**Concentration:** 91 datasets in Isalo, 63 in Makay; top dataset 29.4% / 32.1% of records; top-3 60.9% / 71.9%; top-5 83.4% / 87.2%. Both areas rest on a handful of campaigns.

**Repeated coordinates:** four distinct coordinate pairs hold **50% of all Isalo occurrences** (top pair 12,366 records = 23%), consistent with centroid georeferencing of bulk samples; Makay's top pair holds 3%, and 43 coordinates are needed to reach 50%. Occurrence density for Isalo therefore partly measures georeferencing practice, not sampling intensity.

**Temporal peaks:** Isalo 2022 (9,881), 2010 (9,636), 2023 (7,331); Makay 2010 (4,080 — 56% of all Makay records), 2022 (1,305). Shared peak years suggest the same national campaigns touch both areas.

**Sensitivity summary** (occurrences / accepted species / vascular species; density ratio = Isalo/Makay):

| Filter | Isalo | Makay | Occ. density ratio | Species density ratio |
|---|---|---|---|---|
| S1 Baseline | 53,115 / 1,486 / 622 | 7,341 / 883 / 524 | 33.9× | 7.9× |
| S2 Excl. largest dataset | 37,474 / 1,445 / 622 | 4,986 / 808 / 452 | 35.2× | 8.4× |
| S3 Excl. top-3 datasets | 20,791 / 1,334 / 622 | 2,062 / 459 / 165 | 47.2× | 13.6× |
| S4 Preserved specimens only | 4,955 / 668 / 450 | 5,995 / 727 / 514 | 3.9× | 4.3× |
| S5 Excl. uncertainty > 1 km | 51,560 / 1,421 / 586 | 7,179 / 856 / 518 | 33.6× | 7.8× |
| S6 Known uncertainty ≤ 10 km only | 3,004 / 525 / 257 | 373 / 153 / 23 | 37.7× | 16.1× |
| S7 Excl. iNaturalist | 49,223 / 1,183 / 465 | 6,863 / 787 / 515 | 33.6× | 7.1× |

**Reading:** the "unequal GBIF documentation" conclusion is robust in direction (occurrence-density contrast 34×–47×; species-density contrast 4×–16×) but *not* uniform in mechanism: (i) among preserved specimens, Makay holds **more** records and species than Isalo — the asymmetry is specific to recent molecular/checklist campaigns; (ii) excluding the top three datasets hurts Makay more (72% of its records in its top 3 vs 61% for Isalo); (iii) for vascular plants the raw species counts are nearly equal (ratios 0.9–1.4× under most filters); (iv) coordinate-uncertainty filtering has little leverage because only ~7% of records carry any uncertainty value (median ~250 m where present).

## 8. Interpretation boundaries

- GBIF occurrence and species counts are **documentation indicators**, not estimates of ecological species richness. They are not sampling-completeness measures (no coverage estimators were fitted, and the data do not support one given centroid-stacked coordinates and rank-heterogeneous identifications).
- The all-taxon contrast is dominated by one campaign type (molecular bulk sampling in Isalo); it should not be read as a biodiversity difference.
- The area-normalised densities compound two unequal factors: polygon size and georeferencing practice.
- Makay's polygon is a proposed protected area; Isalo's is a gazetted national park.

## 9. Files changed / produced by the audit

- `R/convert_gbif_madagascar_to_parquet.R` — rewritten (DuckDB-based), documents both conversion defects; produces the corrected parquet (3,635,415 records, 50 columns).
- `data/parquet/gbif_madagascar` — corrected dataset (superseded data in `data/parquet/gbif_madagascar.zip` and `data/parquet/gbif_madagascar_legacy_bugged/`).
- `makay_isalo_report.qmd` / `.html` — updated and re-rendered (provenance, species definition, three scopes, sampling profile, sensitivity, audit notes; original structure and visuals preserved).
- `outputs/audit/*.csv` — all audit tables (comparison, sensitivity, datasets, basis, overlap, record flow, provenance, legacy-vs-corrected).
- `outputs/gbif_dataset_names.csv` — dataset titles fetched from the GBIF dataset API (2026-11-13).
- `audit_report.md`, `manuscript_text_draft.md` — this report and the manuscript text proposals.
- Git: pre-audit snapshot committed (`be9ecf2`); `.gitignore` added for large data files. `results_interpretation.md` was deliberately left unmodified (its figures are superseded; see §4).
