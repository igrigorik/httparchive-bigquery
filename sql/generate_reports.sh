#!/bin/bash
#
# Updates the JSON reports on Google Storage with the latest BigQuery data.
#
# Usage:
#
#   $ sql/generateReports.sh -t -h YYYY_MM_DD
#
# Flags:
#
#   -t: Whether to generate timeseries.
#
#   -h: Whether to generate histograms. Must be accompanied by the date to query.
#
#   -f: Whether to force querying and updating even if the data exists.
#
#   -l: Optional name of the report lens to generate, eg "top10k".
#
#   -r: Optional name of the report files to generate, eg "*crux*".
#

set -o pipefail

BQ_CMD="bq --format prettyjson --project_id httparchive query --max_rows 1000000"
FORCE=0
GENERATE_HISTOGRAM=0
GENERATE_TIMESERIES=0
LENS_ARG=""
REPORTS="*"
VERBOSE=0

# Read the flags.
while getopts ":ftvh:l:r:" opt; do
  case "${opt}" in
    h)
      GENERATE_HISTOGRAM=1
      YYYY_MM_DD=${OPTARG}
      dateParts=(`echo ${OPTARG} | tr "_" "\\n"`)
      YYYYMM=${dateParts[0]}${dateParts[1]}
      DATE=${dateParts[0]}-${dateParts[1]}-${dateParts[2]}
      ;;
    t)
      GENERATE_TIMESERIES=1
      ;;
    v)
      VERBOSE=1
      ;;
    f)
      FORCE=1
      ;;
    l)
      LENS_ARG=${OPTARG}
      ;;
    r)
      REPORTS=${OPTARG}
      ;;
  esac
done

# Exit early if there is nothing to do.
if [ $GENERATE_HISTOGRAM -eq 0 -a $GENERATE_TIMESERIES -eq 0 ]; then
  echo -e "You must provide one or both -t or -h flags." >&2
  echo -e "For example: sql/generateReports.sh -t -h 2017_08_01" >&2
  exit 1
fi

# Check if all tables for the given date are available in BigQuery.
# Tables representing desktop/mobile and HAR/CSV data sources must exist.
DATED_TABLES_READY=0
if [ -n "$YYYY_MM_DD" ]; then
  echo "Checking if tables are ready for ${DATE}..."
  DESKTOP_ROOT_PAGES_EXIST=$(bq query --nouse_legacy_sql --format csv --headless -q "SELECT true FROM httparchive.crawl.pages WHERE date = '${DATE}' AND client = 'desktop' AND is_root_page LIMIT 1" | tail -1)
  DESKTOP_NON_ROOT_PAGES_EXIST=$(bq query --nouse_legacy_sql --format csv --headless -q "SELECT true FROM httparchive.crawl.pages WHERE date = '${DATE}' AND client = 'desktop' AND is_root_page LIMIT 1" | tail -1)
  MOBILE_ROOT_PAGES_EXIST=$(bq query --nouse_legacy_sql --format csv --headless -q "SELECT true FROM httparchive.crawl.pages WHERE date = '${DATE}' AND client = 'mobile' AND NOT is_root_page LIMIT 1" | tail -1)
  MOBILE_NON_ROOT_PAGES_EXIST=$(bq query --nouse_legacy_sql --format csv --headless -q "SELECT true FROM httparchive.crawl.pages WHERE date = '${DATE}' AND client = 'mobile' AND NOT is_root_page LIMIT 1" | tail -1)
  DESKTOP_ROOT_REQUESTS_EXIST=$(bq query --nouse_legacy_sql --format csv --headless -q "SELECT true FROM httparchive.crawl.requests WHERE date = '${DATE}' AND client = 'desktop' AND is_root_page LIMIT 1" | tail -1)
  DESKTOP_NON_ROOT_REQUESTS_EXIST=$(bq query --nouse_legacy_sql --format csv --headless -q "SELECT true FROM httparchive.crawl.requests WHERE date = '${DATE}' AND client = 'desktop' AND is_root_page LIMIT 1" | tail -1)
  MOBILE_ROOT_REQUESTS_EXIST=$(bq query --nouse_legacy_sql --format csv --headless -q "SELECT true FROM httparchive.crawl.requests WHERE date = '${DATE}' AND client = 'mobile' AND NOT is_root_page LIMIT 1" | tail -1)
  MOBILE_NON_ROOT_REQUESTS_EXIST=$(bq query --nouse_legacy_sql --format csv --headless -q "SELECT true FROM httparchive.crawl.requests WHERE date = '${DATE}' AND client = 'mobile' AND NOT is_root_page LIMIT 1" | tail -1)
  echo "Finished checking if dates are ready"
  if [[ "$DESKTOP_ROOT_PAGES_EXIST" == true && "$DESKTOP_NON_ROOT_PAGES_EXIST" == true && "$MOBILE_ROOT_PAGES_EXIST" == true && "$MOBILE_NON_ROOT_PAGES_EXIST" == true && "$DESKTOP_ROOT_REQUESTS_EXIST" == true && "$DESKTOP_NON_ROOT_REQUESTS_EXIST" == true && "$MOBILE_ROOT_REQUESTS_EXIST" == true && "$MOBILE_NON_ROOT_REQUESTS_EXIST" == true ]]; then
    DATED_TABLES_READY=1
  fi
fi
if [ $GENERATE_HISTOGRAM -ne 0 -a $DATED_TABLES_READY -ne 1 ]; then
  echo -e "The BigQuery tables for $DATE are not available." >&2

  # List table data for debugging
  echo $(date)
  echo "Desktop root pages ready: ${DESKTOP_ROOT_PAGES_EXIST}"
  echo "Desktop non-root pages ready: ${DESKTOP_NON_ROOT_PAGES_EXIST}"
  echo "Mobile root pages ready: ${MOBILE_ROOT_PAGES_EXIST}"
  echo "Mobile non-root pages ready: ${MOBILE_NON_ROOT_PAGES_EXIST}"
  echo "Desktop root requests ready: ${DESKTOP_ROOT_REQUESTS_EXIST}"
  echo "Desktop non-root requests ready: ${DESKTOP_NON_ROOT_REQUESTS_EXIST}"
  echo "Mobile root requests ready: ${MOBILE_ROOT_REQUESTS_EXIST}"
  echo "Mobile non-root requests ready: ${MOBILE_NON_ROOT_REQUESTS_EXIST}"
  exit 1
fi

if [ $GENERATE_HISTOGRAM -eq 0 ]; then
  echo -e "Skipping histograms"
else
  echo -e "Generating histograms for date $DATE"

  # Run all histogram queries.
  for query in sql/histograms/$REPORTS.sql; do

    if [[ ! -f $query ]]; then
      echo "Nothing to do"
      continue;
    fi

    # Extract the metric name from the file path.
    # For example, `sql/histograms/foo.sql` will produce `foo`.
    metric=$(echo $(basename $query) | cut -d"." -f1)

    echo -e "Generating $metric histogram"

    if [[ "${LENS_ARG}" == "" ]]; then
      LENSES=("")
      echo "Generating ${metric} report for base"
    elif [[ "${LENS_ARG}" == "ALL" ]]; then
      LENSES=("" $(ls sql/lens))
      echo "Generating ${metric} report for base and all lenses"
    else
      LENSES=("${LENS_ARG}")
      echo "Generating ${metric} report for one lens"
    fi

    for LENS in "${LENSES[@]}"
    do

      gs_lens_dir=""
      if [[ $LENS != "" ]]; then
        if [ ! -f "sql/lens/$LENS/histograms.sql" ] || [ ! -f "sql/lens/$LENS/timeseries.sql" ]; then
          echo -e "Lens histogram/timeseries files not found in sql/lens/$LENS."
          exit 1
        fi
        gs_lens_dir="$LENS/"
      fi

      gs_url="gs://httparchive/reports/$gs_lens_dir$YYYY_MM_DD/${metric}.json"
      gsutil ls $gs_url &> /dev/null
      if [ $? -eq 0 ] && [ $FORCE -eq 0 ]; then
        # The file already exists, so skip the query.
        echo -e "Skipping $gs_lens_dir$YYYY_MM_DD/$metric histogram as already exists"
        continue
      fi

      # Replace the date template in the query.
      if [[ $LENS != "" ]]; then
        echo -e "Generating ${metric} report for $LENS"
        lens_clause="$(cat sql/lens/$LENS/histograms.sql)"
        lens_clause_and="$(cat sql/lens/$LENS/histograms.sql) AND"
        lens_join=""

        if [[ $metric == crux* ]]; then
          lens_clause=""
          lens_clause_and=""
          if [[ -f sql/lens/$LENS/crux_histograms.sql ]]; then
            echo "Using alternative crux lens join"
            lens_join="$(cat sql/lens/$LENS/crux_histograms.sql | tr '\n' ' ')"
          else
            echo "CrUX queries do not support histograms for this lens so skipping"
            continue
          fi

          sql=$(sed -e "s/\(\`chrome-ux-report[^\`]*\`\)/\1 $lens_join/" $query \
            | sed -e "s/\${YYYY-MM-DD}/$DATE/g" \
            | sed -e "s/\${YYYYMM}/$YYYYMM/g")
        else

          if [[ $(grep -i "WHERE" $query) ]]; then
            # If WHERE clause already exists then add to it
            sql=$(sed -e "s/\(WHERE\)/\1 $lens_clause_and /" $query \
              | sed -e "s/\${YYYY-MM-DD}/$DATE/g" \
              | sed -e "s/\${YYYYMM}/$YYYYMM/g")
          else
            # If WHERE clause does not exists then add it, before GROUP BY
            sql=$(sed -e "s/\(GROUP BY\)/WHERE $lens_clause \1/" $query \
              | sed -e "s/\${YYYY-MM-DD}/$DATE/g" \
              | sed -e "s/\${YYYYMM}/$YYYYMM/g")
          fi
        fi
      else
        echo -e "Generating ${metric} report for base (no lens)"
        sql=$(sed -e "s/\${YYYY-MM-DD}/$DATE/g" $query \
          | sed -e "s/\${YYYYMM}/$YYYYMM/g")
      fi

      if [ ${VERBOSE} -eq 1 ]; then
        echo "Running this query:"
        echo "${sql}\n"
      fi

      # Run the histogram query on BigQuery.
      START_TIME=$SECONDS
      result=$(echo "${sql}" | $BQ_CMD)

      # Make sure the query succeeded.
      if [ $? -eq 0 ]; then
        ELAPSED_TIME=$(($SECONDS - $START_TIME))
        if [[ $LENS != "" ]]; then
          echo "$metric for $LENS took $ELAPSED_TIME seconds"
        else
          echo "$metric took $ELAPSED_TIME seconds"
        fi
        # Upload the response to Google Storage.
        echo $result \
          | gsutil  -h "Content-Type:application/json" cp - $gs_url
      else
        echo $result >&2
      fi
    done
  done
fi

if [ $GENERATE_TIMESERIES -eq 0 ]; then
  echo -e "Skipping timeseries"
else
  echo -e "Generating timeseries"

  # Run all timeseries queries.
  for query in sql/timeseries/$REPORTS.sql; do

    if [[ ! -f $query ]]; then
      echo "Nothing to do"
      continue;
    fi

    # Extract the metric name from the file path.
    metric=$(echo $(basename $query) | cut -d"." -f1)

    if [[ "${LENS_ARG}" == "" ]]; then
      LENSES=("")
      echo "Generating ${metric} report for base"
    elif [[ "${LENS_ARG}" == "ALL" ]]; then
      LENSES=("" $(ls sql/lens))
      echo "Generating ${metric} report for base and all lenses"
    else
      LENSES=("${LENS_ARG}")
      echo "Generating ${metric} report for one lens"
    fi

    for LENS in "${LENSES[@]}"
    do

      gs_lens_dir=""
      if [[ $LENS != "" ]]; then
        if [ ! -f "sql/lens/$LENS/histograms.sql" ] || [ ! -f "sql/lens/$LENS/timeseries.sql" ]; then
          echo -e "Lens histogram/timeseries files not found in sql/lens/$LENS."
          exit 1
        fi
        gs_lens_dir="$LENS/"
      fi

      date_join=""
      max_date=""
      current_contents=""
      gs_url="gs://httparchive/reports/$gs_lens_dir${metric}.json"
      gsutil ls $gs_url &> /dev/null
      if [ $? -eq 0 ]; then
        # The file already exists, so check max date
        current_contents=$(gsutil cat $gs_url)
        max_date=$(echo $current_contents | jq -r '[ .[] | .date ] | max')
        if [[ $FORCE -eq 0 && -n "${max_date}" ]]; then

          # Only run if new dates
          if [[ -z "${YYYY_MM_DD}" || "${max_date}" < "${YYYY_MM_DD}" ]]; then
            if [[ $metric != crux* ]]; then # CrUX is quick and join is more compilicated so just do a full run of that
              date_join="date > CAST(REPLACE(\"$max_date\",\"_\",\"-\") AS DATE)"
              # Skip 2022_05_12 tables
              date_join="${date_join}"
              if [[ -n "$YYYY_MM_DD" ]]; then
                # If a date is given, then only run up until then (in case next month is mid run as do not wanna get just desktop data)
                date_join="${date_join} AND date <= \"$DATE\""
              fi
            fi

            echo -e "Generating $gs_lens_dir$metric timeseries in incremental mode from ${max_date} to ${YYYY_MM_DD}"

          else
            echo -e "Skipping $gs_lens_dir$metric timeseries as ${YYYY_MM_DD} already exists in the data. Run in force mode (-f) if you want to rerun."
            continue
          fi

        elif [[ -n "$YYYY_MM_DD" ]]; then
          # Even if doing a force run we only wanna run up until date given in case next month is mid-run as do not wanna get just desktop data
          if [[ $metric != crux* ]]; then # CrUX is quick and join is more compilicated so just do a full run of that
            # If a date is given, then only run up until then (in case next month is mid run as do not wanna get just desktop data)
            date_join="date <= \"$DATE\""
            # Skip 2022_05_12 tables
            date_join="${date_join}"
          fi

          echo -e "Force Mode=${FORCE}. Generating $gs_lens_dir$metric timeseries from start until ${YYYY_MM_DD}."
        fi
      elif [[ -n "$YYYY_MM_DD" ]]; then
        # Even if the file does not exist we only wanna run up until date given in case next month is mid-run as do not wanna get just desktop data
        if [[ $metric != crux* ]]; then # CrUX is quick and join is more compilicated so just do a full run of that
          date_join="date <= \"$DATE\""
          # Skip 2022_05_12 tables
          date_join="${date_join}"
        fi

        echo -e "Timeseries does not exist. Generating $gs_lens_dir$metric timeseries from start until ${YYYY_MM_DD}"

      else
        echo -e "Timeseries does not exist. Generating $gs_lens_dir$metric timeseries from start"
      fi

      if [[ $LENS != "" ]]; then

        if [[ $metric != crux* ]]; then
          lens_clause="$(cat sql/lens/$LENS/timeseries.sql)"
          lens_clause_and="$(cat sql/lens/$LENS/timeseries.sql) AND"
          lens_join=""
        else
          echo "CrUX query so using alternative lens join"
          lens_clause=""
          lens_clause_and=""
          lens_join="$(cat sql/lens/$LENS/crux_timeseries.sql | tr '\n' ' ')"
        fi

        if [[ -n "${date_join}" ]]; then
          if [[ $(grep -i "WHERE" $query) ]]; then
            # If WHERE clause already exists then add to it
            sql=$(sed -e "s/\(WHERE\)/\1 $lens_clause_and $date_join AND/" $query \
              | sed -e "s/\(\`[^\`]*\`)*\)/\1 $lens_join/")
          else
            # If WHERE clause does not exists then add it, before GROUP BY
            sql=$(sed -e "s/\(GROUP BY\)/WHERE $lens_clause_and $date_join \1/" $query \
              | sed -e "s/\(\`[^\`]*\`)*\)/\1 $lens_join/")
          fi
        else
          if [[ $(grep -i "WHERE" $query) ]]; then
            # If WHERE clause already exists then add to it
            sql=$(sed -e "s/\(WHERE\)/\1 $lens_clause_and /" $query \
              | sed -e "s/\(\`[^\`]*\`)*\)/\1 $lens_join/")
          else
            # If WHERE clause does not exists then add it, before GROUP BY
            sql=$(sed -e "s/\(GROUP BY\)/WHERE $lens_clause \1/" $query \
              | sed -e "s/\(\`[^\`]*\`)*\)/\1 $lens_join/")
          fi
        fi

      else
        if [[ -n "${date_join}" ]]; then
          if [[ $(grep -i "WHERE" $query) ]]; then
            # If WHERE clause already exists then add to it
            sql=$(sed -e "s/\(WHERE\)/\1 $date_join AND /" $query)
          else
            # If WHERE clause does not exists then add it, before GROUP BY
            sql=$(sed -e "s/\(GROUP BY\)/WHERE $date_join \1/" $query)
          fi
        else
          sql=$(cat $query)
        fi
      fi

      if [ ${VERBOSE} -eq 1 ]; then
        echo "Running this query:"
        echo "${sql}\n"
      fi

      # Run the timeseries query on BigQuery.
      START_TIME=$SECONDS
      result=$(echo "${sql}" | $BQ_CMD)

      # Make sure the query succeeded.
      if [ $? -eq 0 ]; then
        ELAPSED_TIME=$(($SECONDS - $START_TIME))
        if [[ $LENS != "" ]]; then
          echo "$metric for $LENS took $ELAPSED_TIME seconds"
        else
          echo "$metric took $ELAPSED_TIME seconds"
        fi

        # If it is a partial run, then combine with the current results.
        if [[ $FORCE -eq 0 && -n "${current_contents}" && $metric != crux* ]]; then
          result=$(echo ${result} ${current_contents} | jq '.+= input')
        fi

        # Upload the response to Google Storage.
        echo $result \
          | gsutil  -h "Content-Type:application/json" cp - $gs_url
      else
        echo $result >&2
      fi
    done
  done
fi

echo -e "Done"
