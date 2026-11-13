library(arrow)
library(dplyr)
library(ggplot2)
library(readr)
library(scales)
library(sf)
library(stringr)
library(tibble)
library(tidyr)
library(wdpar)

gbif_columns_to_read <- c(
  "gbifID",
  "decimalLongitude",
  "decimalLatitude",
  "species",
  "scientificName",
  "year",
  "datasetName",
  "datasetKey",
  "institutionCode",
  "publishingOrgKey",
  "basisOfRecord",
  "class",
  "iucnRedListCategory",
  "genus",
  "family",
  "coordinateUncertaintyInMeters",
  "occurrenceStatus",
  "issue"
)

# Define project paths.
get_script_path <- function() {
  command_args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", command_args, value = TRUE)

  if (length(file_arg) > 0) {
    return(normalizePath(sub("^--file=", "", file_arg[[1]])))
  }

  if (!is.null(sys.frames()[[1]]$ofile)) {
    return(normalizePath(sys.frames()[[1]]$ofile))
  }

  normalizePath(file.path(getwd(), "R", "compare_makay_isalo.R"), mustWork = FALSE)
}

# Return a single value when a vector contains data.
safe_min <- function(x) {
  if (all(is.na(x))) {
    return(NA_integer_)
  }

  min(x, na.rm = TRUE)
}

safe_max <- function(x) {
  if (all(is.na(x))) {
    return(NA_integer_)
  }

  max(x, na.rm = TRUE)
}

safe_median <- function(x) {
  if (all(is.na(x))) {
    return(NA_real_)
  }

  median(x, na.rm = TRUE)
}

# Convert list columns before writing flat files.
flatten_list_columns <- function(data) {
  list_columns <- vapply(data, is.list, logical(1))

  if (!any(list_columns)) {
    return(data)
  }

  data[list_columns] <- lapply(
    data[list_columns],
    \(column) vapply(
      column,
      \(value) {
        if (length(value) == 0 || all(is.na(value))) {
          return(NA_character_)
        }

        paste(as.character(unlist(value)), collapse = "; ")
      },
      character(1)
    )
  )

  data
}

# Add missing columns that may be absent in some datasets.
ensure_columns <- function(data, columns, default = NA_character_) {
  missing_columns <- setdiff(columns, names(data))

  if (length(missing_columns) == 0) {
    return(data)
  }

  for (column_name in missing_columns) {
    data[[column_name]] <- default
  }

  data
}

# Standardize the WDPA object returned by wdpar.
prepare_wdpa_data <- function(wdpa_data) {
  if (!inherits(wdpa_data, "sf")) {
    stop("The WDPA input must be an sf object.")
  }

  if (!("SHAPE" %in% names(wdpa_data))) {
    stop("The WDPA download does not contain the expected SHAPE geometry column.")
  }

  wdpa_data |>
    st_as_sf(sf_column_name = "SHAPE") |>
    rename(geometry = SHAPE) |>
    st_as_sf(sf_column_name = "geometry") |>
    st_make_valid() |>
    mutate(
      AREA_KM2 = as.numeric(st_area(st_transform(geometry, 6933))) / 1000000,
      STATUS = trimws(STATUS),
      SITE_TYPE = coalesce(SITE_TYPE, "Unknown"),
      REALM = coalesce(REALM, "Unknown")
    )
}

# Keep the WDPA sites needed for the comparison.
select_target_areas <- function(wdpa_data) {
  wdpa_data |>
    mutate(
      wdpa_name = coalesce(NAME_ENG, NAME),
      area = case_when(
        str_detect(wdpa_name, regex("makay", ignore_case = TRUE)) ~ "Makay",
        str_detect(wdpa_name, regex("isalo", ignore_case = TRUE)) ~ "Isalo",
        TRUE ~ NA_character_
      )
    ) |>
    filter(!is.na(area))
}

# Build one geometry per target area.
summarise_target_areas <- function(target_areas) {
  target_areas |>
    group_by(area) |>
    summarise(
      wdpa_names = str_c(sort(unique(wdpa_name)), collapse = " | "),
      wdpa_site_count = n(),
      wdpa_reported_area_km2 = sum(AREA_KM2, na.rm = TRUE),
      .groups = "drop"
    ) |>
    mutate(wdpa_union_area_km2 = as.numeric(st_area(geometry)) / 1000000)
}

# Build a bounding box table used for parquet filtering.
make_area_bboxes <- function(protected_areas) {
  bbox_matrix <- t(vapply(
    st_geometry(st_transform(protected_areas, 4326)),
    \(geometry) unname(st_bbox(geometry)),
    numeric(4)
  ))

  bbox_table <- as_tibble(bbox_matrix, .name_repair = ~ c("xmin", "ymin", "xmax", "ymax"))

  bind_cols(
    st_drop_geometry(protected_areas) |> select(area),
    bbox_table
  ) |>
    mutate(
      lon_bin_min = floor(xmin),
      lon_bin_max = floor(xmax),
      lat_bin_min = floor(ymin),
      lat_bin_max = floor(ymax)
    )
}

# Read only parquet partitions overlapping the target bounding boxes.
read_occurrences_from_parquet <- function(parquet_dir, area_bboxes) {
  if (!dir.exists(parquet_dir)) {
    stop(
      paste(
        "The parquet dataset was not found.",
        "Run R/convert_gbif_madagascar_to_parquet.R first."
      )
    )
  }

  lon_bins <- seq(min(area_bboxes$lon_bin_min), max(area_bboxes$lon_bin_max))
  lat_bins <- seq(min(area_bboxes$lat_bin_min), max(area_bboxes$lat_bin_max))

  open_dataset(parquet_dir, format = "parquet") |>
    select(any_of(c(gbif_columns_to_read, "lon_bin", "lat_bin"))) |>
    filter(
      lon_bin %in% lon_bins,
      lat_bin %in% lat_bins,
      !is.na(decimalLongitude),
      !is.na(decimalLatitude),
      is.na(occurrenceStatus) | occurrenceStatus == "PRESENT"
    ) |>
    collect()
}

# Keep only records inside at least one target bounding box.
filter_occurrences_to_bboxes <- function(occurrences, area_bboxes) {
  keep_rows <- vapply(
    seq_len(nrow(occurrences)),
    \(row_index) {
      longitude <- occurrences$decimalLongitude[[row_index]]
      latitude <- occurrences$decimalLatitude[[row_index]]

      any(
        longitude >= area_bboxes$xmin &
          longitude <= area_bboxes$xmax &
          latitude >= area_bboxes$ymin &
          latitude <= area_bboxes$ymax
      )
    },
    logical(1)
  )

  occurrences[keep_rows, ]
}

# Count bbox matches for each area before polygon clipping.
summarise_bbox_matches <- function(occurrences, area_bboxes) {
  area_bboxes |>
    rowwise() |>
    mutate(
      gbif_bbox_count = sum(
        occurrences$decimalLongitude >= xmin &
          occurrences$decimalLongitude <= xmax &
          occurrences$decimalLatitude >= ymin &
          occurrences$decimalLatitude <= ymax
      )
    ) |>
    ungroup() |>
    select(area, gbif_bbox_count)
}

# Convert the candidate records to sf for polygon clipping.
prepare_gbif_occurrences <- function(gbif_data) {
  gbif_data |>
    ensure_columns(gbif_columns_to_read) |>
    st_as_sf(
      coords = c("decimalLongitude", "decimalLatitude"),
      crs = 4326,
      remove = FALSE
    )
}

# Clip bbox-filtered records to Makay and Isalo.
clip_occurrences_to_areas <- function(occurrences_sf, protected_areas) {
  protected_areas_wgs84 <- protected_areas |>
    st_transform(4326) |>
    select(area)

  occurrence_index <- st_within(occurrences_sf, protected_areas_wgs84)

  matched_rows <- lengths(occurrence_index) > 0
  matched_areas <- vapply(
    occurrence_index[matched_rows],
    \(index) protected_areas_wgs84$area[[index[[1]]]],
    character(1)
  )

  occurrences_sf[matched_rows, ] |>
    mutate(area = matched_areas, .before = 1) |>
    st_drop_geometry() |>
    mutate(
      species_label = coalesce(species, scientificName),
      record_year = suppressWarnings(as.integer(year)),
      dataset_label = coalesce(datasetName, datasetKey),
      institution_label = coalesce(institutionCode, publishingOrgKey)
    )
}

# Summarize sampling effort and richness per area.
summarise_occurrences <- function(occurrences) {
  occurrences |>
    summarise(
      occurrence_count = n(),
      species_count = n_distinct(species_label, na.rm = TRUE),
      genus_count = n_distinct(genus, na.rm = TRUE),
      family_count = n_distinct(family, na.rm = TRUE),
      dataset_count = n_distinct(dataset_label, na.rm = TRUE),
      institution_count = n_distinct(institution_label, na.rm = TRUE),
      first_year = safe_min(record_year),
      last_year = safe_max(record_year),
      median_coordinate_uncertainty_m = safe_median(coordinateUncertaintyInMeters),
      .by = area
    )
}

# Compare composition across common descriptive dimensions.
make_basis_comparison <- function(occurrences) {
  occurrences |>
    count(area, basisOfRecord, name = "occurrence_count") |>
    mutate(basisOfRecord = replace_na(basisOfRecord, "Unknown")) |>
    group_by(area) |>
    mutate(share = occurrence_count / sum(occurrence_count)) |>
    ungroup() |>
    arrange(area, desc(occurrence_count))
}

make_class_comparison <- function(occurrences) {
  occurrences |>
    distinct(area, class, species_label) |>
    filter(!is.na(class), !is.na(species_label)) |>
    count(area, class, name = "species_count") |>
    arrange(area, desc(species_count))
}

make_yearly_comparison <- function(occurrences) {
  occurrences |>
    filter(!is.na(record_year)) |>
    count(area, record_year, name = "occurrence_count") |>
    arrange(area, record_year)
}

make_iucn_comparison <- function(occurrences) {
  occurrences |>
    count(area, iucnRedListCategory, name = "occurrence_count") |>
    mutate(iucnRedListCategory = replace_na(iucnRedListCategory, "Unknown")) |>
    arrange(area, desc(occurrence_count))
}

make_top_species <- function(occurrences) {
  occurrences |>
    filter(!is.na(species_label)) |>
    count(area, species_label, sort = TRUE, name = "occurrence_count") |>
    group_by(area) |>
    slice_max(occurrence_count, n = 20, with_ties = FALSE) |>
    ungroup()
}

# Measure species overlap between Makay and Isalo.
make_overlap_outputs <- function(occurrences) {
  species_presence <- occurrences |>
    distinct(area, species_label) |>
    filter(!is.na(species_label))

  shared_species <- species_presence |>
    count(species_label, name = "area_count") |>
    filter(area_count == 2L) |>
    select(-area_count)

  unique_species <- species_presence |>
    add_count(species_label, name = "area_count") |>
    filter(area_count == 1L) |>
    select(area, species_label) |>
    arrange(area, species_label)

  species_overlap <- species_presence |>
    count(area, name = "species_count")

  shared_species_count <- nrow(shared_species)
  species_union_count <- n_distinct(species_presence$species_label)
  species_total_count <- sum(species_overlap$species_count)

  overlap_metrics <- tibble(
    shared_species_count = shared_species_count,
    species_union_count = species_union_count,
    jaccard_similarity = if (species_union_count == 0) NA_real_ else shared_species_count / species_union_count,
    sorensen_similarity = if (species_total_count == 0) NA_real_ else 2 * shared_species_count / species_total_count
  )

  list(
    species_presence = species_presence,
    shared_species = shared_species,
    unique_species = unique_species,
    overlap_metrics = overlap_metrics
  )
}

# Create plots used in the comparison report.
make_plots <- function(area_summary, yearly_comparison, basis_comparison, class_comparison) {
  top_classes <- class_comparison |>
    summarise(total_species = sum(species_count), .by = class) |>
    slice_max(total_species, n = 10, with_ties = FALSE) |>
    pull(class)

  occurrence_plot <- area_summary |>
    select(area, occurrence_count, species_count) |>
    pivot_longer(
      cols = c(occurrence_count, species_count),
      names_to = "metric",
      values_to = "value"
    ) |>
    ggplot(aes(x = area, y = value, fill = metric)) +
    geom_col(position = position_dodge(width = 0.75), width = 0.65) +
    scale_fill_manual(values = c(occurrence_count = "#3b7a57", species_count = "#d97d54")) +
    labs(
      title = "Makay vs Isalo: GBIF records and species richness",
      x = NULL,
      y = "Count",
      fill = NULL
    ) +
    theme_minimal(base_size = 12)

  yearly_plot <- ggplot(yearly_comparison, aes(x = record_year, y = occurrence_count, color = area)) +
    geom_line(linewidth = 0.9) +
    geom_point(size = 1.8) +
    labs(
      title = "Makay vs Isalo: yearly GBIF occurrence counts",
      x = "Year",
      y = "Occurrence count",
      color = NULL
    ) +
    theme_minimal(base_size = 12)

  if (nrow(yearly_comparison) > 0) {
    yearly_plot <- yearly_plot +
      scale_color_manual(values = c(Makay = "#3b7a57", Isalo = "#c85c3e"))
  }

  basis_plot <- basis_comparison |>
    ggplot(aes(x = area, y = share, fill = basisOfRecord)) +
    geom_col(width = 0.65) +
    scale_y_continuous(labels = label_percent()) +
    labs(
      title = "Makay vs Isalo: basis of record composition",
      x = NULL,
      y = "Share of occurrences",
      fill = "Basis of record"
    ) +
    theme_minimal(base_size = 12)

  class_plot_data <- class_comparison |>
    filter(class %in% top_classes)

  class_plot <- ggplot(class_plot_data, aes(x = reorder(class, species_count), y = species_count, fill = area)) +
    geom_col(position = position_dodge(width = 0.75), width = 0.65) +
    coord_flip() +
    labs(
      title = "Makay vs Isalo: species richness by taxonomic class",
      x = NULL,
      y = "Species count",
      fill = NULL
    ) +
    theme_minimal(base_size = 12)

  if (nrow(class_plot_data) > 0) {
    class_plot <- class_plot +
      scale_fill_manual(values = c(Makay = "#3b7a57", Isalo = "#c85c3e"))
  }

  list(
    occurrence_counts = occurrence_plot,
    yearly_counts = yearly_plot,
    basis_of_record = basis_plot,
    class_richness = class_plot
  )
}

# Write all tables and figures to disk.
write_outputs <- function(
  output_dir,
  target_areas,
  protected_areas,
  area_bboxes,
  gbif_meta,
  occurrences,
  area_summary,
  basis_comparison,
  class_comparison,
  yearly_comparison,
  iucn_comparison,
  top_species,
  shared_species,
  unique_species,
  overlap_metrics,
  plots
) {
  write_csv(st_drop_geometry(target_areas), file.path(output_dir, "wdpa_candidate_sites.csv"))
  write_csv(st_drop_geometry(protected_areas), file.path(output_dir, "protected_area_summary.csv"))
  write_csv(area_bboxes, file.path(output_dir, "target_area_bboxes.csv"))
  write_csv(gbif_meta, file.path(output_dir, "gbif_query_summary.csv"))
  write_csv(flatten_list_columns(occurrences), file.path(output_dir, "gbif_occurrences_makay_isalo.csv"))
  write_csv(area_summary, file.path(output_dir, "area_comparison_summary.csv"))
  write_csv(basis_comparison, file.path(output_dir, "basis_of_record_comparison.csv"))
  write_csv(class_comparison, file.path(output_dir, "class_comparison.csv"))
  write_csv(yearly_comparison, file.path(output_dir, "yearly_comparison.csv"))
  write_csv(iucn_comparison, file.path(output_dir, "iucn_red_list_comparison.csv"))
  write_csv(top_species, file.path(output_dir, "top_species_by_area.csv"))
  write_csv(shared_species, file.path(output_dir, "shared_species.csv"))
  write_csv(unique_species, file.path(output_dir, "unique_species.csv"))
  write_csv(overlap_metrics, file.path(output_dir, "species_overlap_metrics.csv"))

  ggsave(
    filename = file.path(output_dir, "occurrence_and_species_counts.png"),
    plot = plots$occurrence_counts,
    width = 8,
    height = 5,
    dpi = 300
  )

  ggsave(
    filename = file.path(output_dir, "yearly_occurrence_counts.png"),
    plot = plots$yearly_counts,
    width = 8,
    height = 5,
    dpi = 300
  )

  ggsave(
    filename = file.path(output_dir, "basis_of_record_composition.png"),
    plot = plots$basis_of_record,
    width = 8,
    height = 5,
    dpi = 300
  )

  ggsave(
    filename = file.path(output_dir, "class_richness_comparison.png"),
    plot = plots$class_richness,
    width = 8,
    height = 6,
    dpi = 300
  )
}

script_path <- get_script_path()
project_root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = FALSE)

data_dir <- file.path(project_root, "data")
raw_dir <- file.path(data_dir, "raw")
wdpa_dir <- file.path(raw_dir, "wdpa")
output_dir <- file.path(project_root, "outputs")
gbif_parquet_dir <- file.path(data_dir, "parquet", "gbif_madagascar")

dir.create(wdpa_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

madagascar_wdpa <- wdpa_fetch(
  "MDG",
  wait = TRUE,
  download_dir = wdpa_dir,
  force_download = FALSE,
  verbose = FALSE
) |>
  prepare_wdpa_data()

target_areas <- select_target_areas(madagascar_wdpa)

if (!all(c("Makay", "Isalo") %in% target_areas$area)) {
  stop("Makay and/or Isalo were not found in the Madagascar WDPA download.")
}

protected_areas <- summarise_target_areas(target_areas)
area_bboxes <- make_area_bboxes(protected_areas)
candidate_occurrences <- read_occurrences_from_parquet(gbif_parquet_dir, area_bboxes)
bbox_occurrences <- filter_occurrences_to_bboxes(candidate_occurrences, area_bboxes)
bbox_occurrences_sf <- prepare_gbif_occurrences(bbox_occurrences)
area_occurrences <- clip_occurrences_to_areas(bbox_occurrences_sf, protected_areas)
bbox_summary <- summarise_bbox_matches(bbox_occurrences, area_bboxes)

gbif_meta <- tibble(
  area = protected_areas$area,
  gbif_fetch_count = nrow(candidate_occurrences),
  gbif_clipped_count = vapply(
    protected_areas$area,
    \(area_name) sum(area_occurrences$area == area_name),
    integer(1)
  ),
  gbif_truncated = FALSE
) |>
  left_join(bbox_summary, by = "area") |>
  select(area, gbif_bbox_count, gbif_fetch_count, gbif_clipped_count, gbif_truncated)

occurrence_summary <- summarise_occurrences(area_occurrences)

area_summary <- protected_areas |>
  st_drop_geometry() |>
  left_join(gbif_meta, by = "area") |>
  left_join(occurrence_summary, by = "area") |>
  mutate(
    occurrence_count = coalesce(occurrence_count, 0L),
    species_count = coalesce(species_count, 0L),
    genus_count = coalesce(genus_count, 0L),
    family_count = coalesce(family_count, 0L),
    dataset_count = coalesce(dataset_count, 0L),
    institution_count = coalesce(institution_count, 0L),
    occurrence_density_per_100_km2 = occurrence_count / wdpa_union_area_km2 * 100,
    species_density_per_100_km2 = species_count / wdpa_union_area_km2 * 100
  )

basis_comparison <- make_basis_comparison(area_occurrences)
class_comparison <- make_class_comparison(area_occurrences)
yearly_comparison <- make_yearly_comparison(area_occurrences)
iucn_comparison <- make_iucn_comparison(area_occurrences)
top_species <- make_top_species(area_occurrences)
overlap_outputs <- make_overlap_outputs(area_occurrences)

plots <- make_plots(
  area_summary = area_summary,
  yearly_comparison = yearly_comparison,
  basis_comparison = basis_comparison,
  class_comparison = class_comparison
)

write_outputs(
  output_dir = output_dir,
  target_areas = target_areas,
  protected_areas = protected_areas,
  area_bboxes = area_bboxes,
  gbif_meta = gbif_meta,
  occurrences = area_occurrences,
  area_summary = area_summary,
  basis_comparison = basis_comparison,
  class_comparison = class_comparison,
  yearly_comparison = yearly_comparison,
  iucn_comparison = iucn_comparison,
  top_species = top_species,
  shared_species = overlap_outputs$shared_species,
  unique_species = overlap_outputs$unique_species,
  overlap_metrics = overlap_outputs$overlap_metrics,
  plots = plots
)

comparison_results <- list(
  protected_areas = protected_areas,
  area_bboxes = area_bboxes,
  gbif_meta = gbif_meta,
  candidate_occurrences = candidate_occurrences,
  occurrences = area_occurrences,
  area_summary = area_summary,
  basis_comparison = basis_comparison,
  class_comparison = class_comparison,
  yearly_comparison = yearly_comparison,
  iucn_comparison = iucn_comparison,
  top_species = top_species,
  shared_species = overlap_outputs$shared_species,
  unique_species = overlap_outputs$unique_species,
  overlap_metrics = overlap_outputs$overlap_metrics,
  plots = plots
)

saveRDS(comparison_results, file.path(output_dir, "makay_isalo_comparison_results.rds"))

comparison_results