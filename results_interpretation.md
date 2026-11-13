# Makay and Isalo GBIF comparison

This workflow uses two spatial filters in sequence.

First, the parquet dataset is queried with the bounding boxes of Makay and Isalo. This is only a prefilter used to avoid loading the full Madagascar extract into memory.

Second, the candidate occurrences are converted to `sf` points and filtered against the exact protected-area polygons with `st_within()`. The final tables and figures therefore describe polygon-clipped occurrences, not simple bounding-box matches.

## Spatial scope and record flow

The WDPA geometries define one polygon for Isalo and one polygon for Makay.

- Isalo union area: about 869 km²
- Makay union area: about 4067 km²
- Candidate occurrences read from parquet partitions overlapping the target bbox bins: 222,529
- Occurrences inside the Isalo bounding box: 63,848
- Occurrences inside the Makay bounding box: 7,640
- Occurrences retained after exact polygon clipping: 49,606 for Isalo and 6,692 for Makay

This means the bbox stage removed most of the Madagascar archive before loading to memory, and the polygon stage then removed additional records that fell inside the rectangular extent but outside the protected-area boundary.

## Main comparison

Isalo has many more GBIF occurrences than Makay.

- Isalo polygon-clipped occurrences: 49,606
- Makay polygon-clipped occurrences: 6,692

Isalo also has more recorded taxonomic diversity in this dataset.

- Isalo species count: 2,749
- Makay species count: 1,293

Makay is much larger than Isalo, so the contrast changes when counts are expressed relative to area.

- Isalo occurrence density per 100 km²: about 5,708
- Makay occurrence density per 100 km²: about 165
- Isalo species density per 100 km²: about 316
- Makay species density per 100 km²: about 32

The broad pattern is that Isalo is much more intensively sampled and has much denser recorded biodiversity information per unit area.

## Sampling profile

The basis of record differs between the two areas.

In Isalo, the dataset is dominated by material samples and then human observations.

- Material sample: 32,655 records, 65.8%
- Human observation: 12,348 records, 24.9%
- Preserved specimen: 4,539 records, 9.2%

In Makay, the dataset is dominated by preserved specimens.

- Preserved specimen: 5,450 records, 81.4%
- Human observation: 644 records, 9.6%
- Material sample: 553 records, 8.3%

This suggests different field and publishing histories. Isalo appears to include a much larger share of recent inventory-style or monitoring-style sampling, whereas Makay remains more specimen-driven.

## Taxonomic composition

Isalo is especially rich in records from invertebrates and plants.

Top classes in Isalo by species count:

- Insecta: 1,087
- Magnoliopsida: 473
- Liliopsida: 233
- Aves: 129
- Arachnida: 105

Makay is also dominated by plants and insects, but with lower absolute richness.

Top classes in Makay by species count:

- Magnoliopsida: 599
- Insecta: 347
- Liliopsida: 102
- Aves: 65
- Polypodiopsida: 51

The areas therefore overlap in broad biological structure, but Isalo is richer in the current GBIF record set across most major groups.

## Species overlap

The overlap between the two areas is limited.

- Shared species count: 483
- Species union count: 3,559
- Jaccard similarity: 0.136
- Sorensen similarity: 0.239

These values indicate that Makay and Isalo share only a modest fraction of their recorded species pools. They are not close substitutes in the GBIF record space.

## Interpretation and caveats

The main signal is a strong asymmetry in sampling intensity.

Isalo has far more GBIF records, more species, more datasets, and much greater occurrence density than Makay. Some of this likely reflects real ecological differences, but a substantial part almost certainly reflects sampling and publication bias.

Makay still contributes distinct biodiversity information.

Despite fewer records, Makay adds many species not shared with Isalo, which is why the overlap metrics remain low.

The current GBIF extract does not provide usable `iucnRedListCategory` information for these records. The red-list comparison output is therefore not informative in this run.

Several highly frequent labels in the top-species table are broad higher-level identifications rather than species-level determinations. That means richness and overlap should be read as GBIF record-derived indicators, not as a definitive floristic or faunistic inventory.

## Practical takeaway

If the goal is to compare research implementation, the current results suggest:

- Isalo has a much deeper and broader GBIF footprint
- Makay remains comparatively underrepresented in accessible occurrence data
- Makay still contains substantial unique recorded biodiversity and should not be treated as redundant relative to Isalo
- Future interpretation should separate ecological contrast from data-availability bias