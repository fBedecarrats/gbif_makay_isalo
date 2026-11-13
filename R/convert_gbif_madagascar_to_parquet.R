# Convert the GBIF occurrence download (SIMPLE_CSV format) to a partitioned
# parquet dataset, one partition per 1-degree lon/lat bin.
#
# Audit revision (2026-11-13), relative to the original readr-based version:
#
# 1. The GBIF CSV contains 262 records with stray unescaped double quotes
#    inside field values (a GBIF writer defect; no field value contains tabs
#    or line breaks, because the file has exactly 3,635,416 lines for
#    3,635,415 records + header). readr::read_tsv_chunked() loses
#    quote-scanner synchronisation on these records and silently dropped
#    300,486 of the 3,635,415 records (233,893 geo-referenced and 66,593
#    without coordinates). DuckDB's CSV reader is used instead, with quoting
#    disabled (quote = '') so that the stray quotes are read as ordinary
#    characters and every record is parsed exactly once.
#
# 2. The original partition loop used `chunk$lon_bin == lon_value` to subset
#    rows. For rows with missing coordinates the comparison returns NA (not
#    FALSE), and subsetting a data frame with logical NA silently creates
#    all-NA rows. Consequence: the legacy parquet contained 70,239,134
#    all-NA "phantom" rows on top of its 2,905,310 real records, while the
#    498,212 coordinate-less records of the download were silently dropped
#    (the "Madagascar present records = 73,144,444" figure in the previous
#    report was the sum of real and phantom rows). The fix keeps coordinate-
#    less records, with their real content, in the
#    __HIVE_DEFAULT_PARTITION__ folder, and no phantom rows exist.
#
# 3. All 50 columns of the SIMPLE_CSV download are kept. The original version
#    kept 16 columns, which made kingdom/phylum/taxonRank/speciesKey-based
#    recounting (accepted species, taxonomic scopes) impossible without
#    re-reading the raw archive.
#
# Geometric fields are typed doubles via try_cast (dirty values become NULL);
# all other columns stay character because GBIF interpretation fields are not
# guaranteed numeric (e.g. corrupt taxonKey values such as "7NL2S" occur in
# this download). Numeric casting of those columns happens downstream, R-side.

library(duckdb)
library(DBI)

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

  normalizePath(
    file.path(getwd(), "R", "convert_gbif_madagascar_to_parquet.R"),
    mustWork = FALSE
  )
}

convert_csv_to_parquet <- function(csv_path, parquet_dir) {
  if (dir.exists(parquet_dir)) {
    stop(
      paste(
        "Refusing to overwrite the existing parquet dataset:", parquet_dir,
        "\nThe superseded legacy dataset is archived in",
        "data/parquet/gbif_madagascar.zip."
      )
    )
  }

  con <- dbConnect(duckdb(), dbdir = ":memory:")
  on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
  dbExecute(con, "SET memory_limit = '6GB'")

  csv_path_sql <- gsub("\\\\", "/", normalizePath(csv_path, winslash = "/"))
  parquet_dir_sql <- gsub("\\\\", "/", normalizePath(parquet_dir, winslash = "/"))

  # quote = '' : the CSV has stray unescaped quotes but no tabs or newlines
  # inside field values, so disabling quote parsing parses every record.
  dbExecute(con, sprintf("
    CREATE OR REPLACE VIEW occ AS
    SELECT * FROM read_csv('%s', delim = '\\t', header = true,
      all_varchar = true, quote = '', escape = '')
  ", csv_path_sql))

  dbExecute(con, "
    CREATE OR REPLACE TABLE occ_typed AS
    SELECT
      gbifID, datasetKey, occurrenceID, kingdom, phylum, class, \"order\", family,
      genus, species, infraspecificEpithet, taxonRank, scientificName,
      verbatimScientificName, verbatimScientificNameAuthorship, countryCode,
      locality, stateProvince, occurrenceStatus, individualCount, publishingOrgKey,
      try_cast(decimalLatitude AS DOUBLE) AS decimalLatitude,
      try_cast(decimalLongitude AS DOUBLE) AS decimalLongitude,
      try_cast(coordinateUncertaintyInMeters AS DOUBLE) AS coordinateUncertaintyInMeters,
      try_cast(coordinatePrecision AS DOUBLE) AS coordinatePrecision,
      try_cast(elevation AS DOUBLE) AS elevation,
      try_cast(elevationAccuracy AS DOUBLE) AS elevationAccuracy,
      try_cast(depth AS DOUBLE) AS depth,
      try_cast(depthAccuracy AS DOUBLE) AS depthAccuracy,
      eventDate, day, month, year, taxonKey, speciesKey, basisOfRecord,
      institutionCode, collectionCode, catalogNumber, recordNumber, identifiedBy,
      dateIdentified, license, rightsHolder, recordedBy, typeStatus,
      establishmentMeans, lastInterpreted, mediaType, issue,
      CAST(floor(try_cast(decimalLongitude AS DOUBLE)) AS INTEGER) AS lon_bin,
      CAST(floor(try_cast(decimalLatitude AS DOUBLE)) AS INTEGER) AS lat_bin
    FROM occ
  ")

  dbExecute(con, sprintf("
    COPY occ_typed TO '%s' (
      FORMAT PARQUET,
      PARTITION_BY (lon_bin, lat_bin),
      FILENAME_PATTERN 'chunk_{i}_data',
      COMPRESSION SNAPPY,
      ROW_GROUP_SIZE 100000
    )
  ", parquet_dir_sql))

  total_records <- dbGetQuery(con, "SELECT count(*) AS n FROM occ_typed")$n
  invisible(list(parquet_dir = parquet_dir, records_written = total_records))
}

script_path <- get_script_path()
project_root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = FALSE)

data_dir <- file.path(project_root, "data")
zip_path <- file.path(data_dir, "0000459-260720095953322.zip")
csv_extract_dir <- file.path(data_dir, "raw", "gbif")
parquet_dir <- file.path(data_dir, "parquet", "gbif_madagascar")

dir.create(csv_extract_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(dirname(parquet_dir), recursive = TRUE, showWarnings = FALSE)

csv_path <- file.path(csv_extract_dir, "0000459-260720095953322.csv")

if (!file.exists(csv_path)) {
  archive_files <- utils::unzip(zip_path, list = TRUE)

  if (nrow(archive_files) != 1) {
    stop("The GBIF archive is expected to contain a single CSV file.")
  }

  utils::unzip(zip_path, files = archive_files$Name[[1]], exdir = csv_extract_dir)
}

result <- convert_csv_to_parquet(csv_path, parquet_dir)

cat(
  sprintf(
    "Wrote %d records to %s\n",
    result$records_written,
    result$parquet_dir
  )
)
