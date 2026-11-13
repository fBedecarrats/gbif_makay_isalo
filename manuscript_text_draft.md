# Draft text proposed for the manuscript

*(Not inserted into the manuscript; for the authors' consideration. All
figures survive the reproducibility audit of 2026-11-13 — see
`audit_report.md`.)*

## Introduction paragraph (119 words)

> Occurrence data mobilised through GBIF offer an uneven picture of plant
> diversity across Madagascar's protected areas. Comparing all GBIF-mediated
> records within the WDPA boundaries of Isalo National Park (866 km²) and the
> proposed Makay protected area (4,056 km²) reveals a strongly unequal
> documentation: 53,115 occurrences and 1,486 accepted species for Isalo
> versus 7,341 occurrences and 883 species for Makay — an approximately
> 34-fold difference in occurrence density and an eight-fold difference in
> recorded-species density. For vascular plants, however, the raw contrast
> narrows to 622 versus 524 species. These figures are shaped by a few
> dominant datasets — molecular bulk sampling in Isalo, herbarium
> digitisation in Makay — and quantify data availability rather than
> ecological richness or research effort per se.

## Methods description (GBIF comparison; ~130 words)

> GBIF-mediated occurrence records for both areas were extracted from a
> single Madagascar download (occurrenceStatus = PRESENT; country = MG;
> GBIF occurrence download 0000459-260720095953322, DOI 10.15468/dl.ufwdju,
> created 20 July 2026; CC BY-NC 4.0). Records were retained when their
> coordinates fell within the WDPA polygons of Isalo National Park (WDPA site
> 2312) and the proposed Makay protected area (site 555790177) from the
> WDPA/WDOECM July 2026 release, using exact point-in-polygon tests; polygon
> areas were computed in an equal-area projection (EPSG:6933). Species were
> counted as distinct GBIF backbone accepted-species identifiers
> (`speciesKey`), which resolves synonyms; identifications above species rank
> were retained as occurrences but excluded from species counts. Comparisons
> were computed for all taxa, Plantae, and vascular plants (Tracheophyta),
> and the robustness of contrasts was assessed by excluding dominant
> datasets, restricting to preserved specimens, and filtering on coordinate
> uncertainty.
