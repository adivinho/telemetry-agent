#!/bin/bash

# SCRIPT:
# -----------------------------
# This script creates and sends data about the host node to the Percona Telemetry service.

set -o pipefail
# set -o xtrace

# Exit script if telemetry is not be collected (only if PERCONA_TELEMETRY_DISABLE=1)
if [[ ${PERCONA_TELEMETRY_DISABLE} -ne "0" ]];
then
    exit 0;
fi

# Script variables
# Can be passed to the script via env variable or via named parameter
PERCONA_TELEMETRY_CONFIG_FILE_PATH="${PERCONA_TELEMETRY_CONFIG_FILE_PATH:-"/usr/local/percona/telemetry_uuid"}"
PERCONA_SEND_TIMEOUT=${PERCONA_SEND_TIMEOUT:-10}
PERCONA_TELEMETRY_URL="${PERCONA_TELEMETRY_URL:-"https://check-dev.percona.com/v1/telemetry/GenericReport"}"
PERCONA_PRODUCT_FAMILY=${PERCONA_PRODUCT_FAMILY}
PERCONA_PRODUCT_VERSION=${PERCONA_PRODUCT_VERSION}
PERCONA_OPERATING_SYSTEM=${PERCONA_OPERATING_SYSTEM}
PERCONA_DEPLOYMENT_METHOD=${PERCONA_DEPLOYMENT_METHOD}
PERCONA_INSTANCE_ID=${PERCONA_INSTANCE_ID}

json_message=""
declare -A json_message_map
declare -A metrics_map
declare -A telemetry_config_map

## USAGE
usage()
{
    errorCode=${1:-0}

    cat << EOF

usage: $0 OPTIONS

Collects telemetry information and sends it to a Telemetry service. The data collection
may be disabled via setting an environment variable [PERCONA_TELEMETRY_DISABLE=1].

The script validates only if mandatory parameters are provided.
It does not check the validity and itegritiy of provided parameters.

The data will be sent to ${PERCONA_TELEMETRY_URL} in a JSON format.

OPTIONS can be:

  -h  Show this message

  -f  [PERCONA_PRODUCT_FAMILY]              Product family identifier.                                  [REQUIRED]
  -v  [PERCONA_PRODUCT_VERSION]             Product version.                                            [REQUIRED]
  -s  [PERCONA_OPERATING_SYSTEM]            Operating system identifier.                                [Default: autodetected with fallback to "unknown"]
  -d  [PERCONA_DEPLOYMENT_METHOD]           Deployment method.                                          [REQUIRED]
  -i  [PERCONA_INSTANCE_ID]                 Instance id                                                 [Default: autogenerated]
  -j  [PERCONA_TELEMETRY_CONFIG_FILE_PATH]  Path of the file where to store the unique ID of this node. [Default: ${PERCONA_TELEMETRY_CONFIG_FILE_PATH}]
  -u  [PERCONA_TELEMETRY_URL]               Percona Telemetry Service endpoint                          [Default: ${PERCONA_TELEMETRY_URL}]
  -t  [PERCONA_SEND_TIMEOUT]                Default timeout for the curl command.                       [Default: ${PERCONA_SEND_TIMEOUT}]

Note that -d PERCONA_PRODUCT_FAMILY can be set to any string, but only the following ones will be accepted
by Percona Telemetry service (there is no validation of the script side):

PRODUCT_FAMILY_PS
PRODUCT_FAMILY_PXC
PRODUCT_FAMILY_PXB
PRODUCT_FAMILY_PSMDB
PRODUCT_FAMILY_PBM
PRODUCT_FAMILY_POSTGRESQL
PRODUCT_FAMILY_PMM
PRODUCT_FAMILY_EVEREST
PRODUCT_FAMILY_PERCONA_TOOLKIT

For example,
on a CentOS7, you may run the script as:

./${0} -f "PRODUCT_FAMILY_PS" -v "8.0.33" -s "\$(cat /etc/redhat-release)" -i "13f5fc62-35b4-4716-b3e6-96c761fc204d" -j /tmp/percona.telemetry -u "https://TO/DO/PROVIDE/ENDPOINT -t 1

on Ubuntu, you may run the script as:
./${0} -f "PRODUCT_FAMILY_PS" -v "8.0.33" -s "\$(cat /etc/issue)" -i "13f5fc62-35b4-4716-b3e6-96c761fc204d" -j /tmp/percona.telemetry -u "https://TO/DO/PROVIDE/ENDPOINT -t 1

EOF

    if [[ ${errorCode} -ne 0 ]];
    then
        exit_script "${errorCode}"
    fi
}

# Perform any required cleanup and exit with the given error/success code
exit_script()
{
    # Exit with a given return code or 0 if none are provided.
    exit "${1:-0}"
}

# Vaildate arguments to ensure that mandatory ones have been provided
validate_args()
{
    local USAGE_TEXT="See usage for details."

    if [[ -z ${PERCONA_PRODUCT_FAMILY} ]];
    then
        echo "PERCONA_PRODUCT_FAMILY is not provided. ${USAGE_TEXT}"
        usage 1
    fi

    if [[ -z ${PERCONA_PRODUCT_VERSION} ]];
    then
        echo "PERCONA_PRODUCT_VERSION is not provided. ${USAGE_TEXT}"
        usage 1
    fi

    if [[ -z ${PERCONA_DEPLOYMENT_METHOD} ]];
    then
        echo "PERCONA_DEPLOYMENT_METHOD is not provided. ${USAGE_TEXT}"
        usage 1
    fi

    if [[ -z ${PERCONA_INSTANCE_ID} ]];
    then
        echo "PERCONA_INSTANCE_ID is not provided. ${USAGE_TEXT}"
        usage 1
    fi
}

detect_operating_system()
{
    # autodetect OS only if it was not explicitly passed via parameter
    if [[ -z ${PERCONA_OPERATING_SYSTEM} ]];
    then
        if [[ -f /etc/os-release ]]
        then
            PERCONA_OPERATING_SYSTEM="$(grep PRETTY_NAME /etc/os-release | sed 's/PRETTY_NAME=//g;s/\"//g')"
        elif [[ -f /etc/system-release ]];
        then
            PERCONA_OPERATING_SYSTEM="$(< /etc/system-release sed 's/\"//g'| head -n1)"
        elif [[ -f /etc/redhat-release ]];
        then
            PERCONA_OPERATING_SYSTEM="$(< /etc/redhat-release sed 's/\"//g'| head -n1)"
        elif [[ -f /etc/issue ]];
        then
            PERCONA_OPERATING_SYSTEM="$(cat /etc/issue)"
            PERCONA_OPERATING_SYSTEM=${PERCONA_OPERATING_SYSTEM//[$'\r\n']}
        fi

        # Fallback to "unknown" if we failed to detect
        if [[ -z ${PERCONA_OPERATING_SYSTEM} ]];
        then
            PERCONA_OPERATING_SYSTEM="unknown"
        fi
    fi
}

# Read k:v from file into telemetry_config_map
read_telemetry_config_file()
{
    if [[ -f "${PERCONA_TELEMETRY_CONFIG_FILE_PATH}" ]];
    then
        while IFS=":" read -r key value;
        do
            # Trim possible leading and trailing whitespaces
            key=$(echo "${key}" | xargs)
            value=$(echo "${value}" | xargs)
            # skip empty keys
            if [[ -n "${key}" ]];
            then
                telemetry_config_map[${key}]=${value}
            fi
        done < "${PERCONA_TELEMETRY_CONFIG_FILE_PATH}"
    fi
}

# Check telemetry_config_map for:
# 1. Existance of the valid instanceId
# 2. If the current product was already reported
#
# If the instanceId stored is valid and the product was already reported, exit the script immediately.
# If the instanceId is not present or is spoiled, generate the new one and force reporting the product.
check_telemetry_config()
{
    local instance_id="${telemetry_config_map["instanceId"]}"

    # If there is no instanceId, or the ID is spoiled, create new ID and force the report
    if [[ $(echo "${instance_id}" | grep -c "^[0-9a-fA-F]\{8\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{12\}$") -ne 1 ]];
    then
        # instanceId may be provided via -i cmdline param
        # If not provided, or provided but not uuid v4, generate new one.
        if [[ $(echo "${PERCONA_INSTANCE_ID}" | grep -c "^[0-9a-fA-F]\{8\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{4\}-[0-9a-fA-F]\{12\}$") -ne 1 ]];
        then
            PERCONA_INSTANCE_ID=
        fi

        if [[ -z "${PERCONA_INSTANCE_ID}" ]];
        then
            PERCONA_INSTANCE_ID=$(cat /proc/sys/kernel/random/uuid)
        fi

        # We have new instanceId, clear the whole config, all products will be reported again with new Id
        telemetry_config_map=()
        telemetry_config_map["instanceId"]="${PERCONA_INSTANCE_ID}"
    else
        PERCONA_INSTANCE_ID="${instance_id}"
    fi

    # Check if this product was already reported
    if [[ -n ${telemetry_config_map[${PERCONA_PRODUCT_FAMILY}]} ]];
    then
        # This product already has been reported, exit script
        # echo "Product already reported. Exiting"
        exit_script
    fi
}

check_if_config_file_writable()
{
    # Make sure the storage directory exists
    mkdir -p "$(dirname "${PERCONA_TELEMETRY_CONFIG_FILE_PATH}")" || return 1
    # Make sure the config file is writable
    printf "config_write_check:1\n" >> "${PERCONA_TELEMETRY_CONFIG_FILE_PATH}" || return 1
}

save_config()
{
    # Truncate config file
    cat /dev/null > "${PERCONA_TELEMETRY_CONFIG_FILE_PATH}"
    for key in "${!telemetry_config_map[@]}"
    do
        printf "%s:%s\n" "${key}" "${telemetry_config_map[${key}]}" >> "${PERCONA_TELEMETRY_CONFIG_FILE_PATH}"
    done
}

mark_product_as_reported()
{
    telemetry_config_map[${PERCONA_PRODUCT_FAMILY}]="1"
    save_config    
}

collect_data_for_report()
{
    json_message_map["id"]=$(cat /proc/sys/kernel/random/uuid)
    json_message_map["createTime"]="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    json_message_map["instanceId"]=${PERCONA_INSTANCE_ID}
    json_message_map["product_family"]=${PERCONA_PRODUCT_FAMILY}

    metrics_map["pillar_version"]=${PERCONA_PRODUCT_VERSION}
    metrics_map["OS"]=${PERCONA_OPERATING_SYSTEM}
    metrics_map["hardware_arch"]="$(uname -mp)"
    metrics_map["deployment"]=${PERCONA_DEPLOYMENT_METHOD}
}


# {
#    "reports":[
#       {
#          "id":"13f5fc62-35b4-4716-b3e6-96c761fc204d",
#          "createTime":"2023-09-15T13:36:53+03:00",
#          "instanceId":"6e5ff5d4-5617-11ee-8c99-0242ac120002",
#          "product_family":"PERCONA_PRODUCT_FAMILY_MYSQL",
#          "metrics":[
#             {
#                "key":"pillar_version",
#                "value":"8.0.30"
#             },
#             {
#                "key":"OS",
#                "value":"Ubuntu 22.04"
#             },
#             {
#                "key":"deployment",
#                "value":"PACKAGE"
#             }
#          ]
#       }
#    ]
# }

# Let's create a single JSON message here.
create_json_message()
{
    json_message="{"
      json_message+="\"reports\":["
        json_message+="{"

          # report header
          for key in "${!json_message_map[@]}"
          do
              m="$(printf "\"%s\" : \"%s\"" "${key}" "${json_message_map[${key}]}")"
              json_message+="${m},"
          done

          # metrics
          local first_metric=1
          json_message+="\"metrics\":["

            for key in "${!metrics_map[@]}"
            do
                if [[ $first_metric -ne 1 ]];
                then
                  json_message+=","
                fi

                json_message+="{"
                m1="$(printf "\"key\" : \"%s\"" "${key}")"
                m2="$(printf "\"value\" : \"%s\"" "${metrics_map[${key}]}")"
                json_message+="${m1},"
                json_message+="${m2}"
                json_message+="}"
                first_metric=0
            done

          json_message+="]"   # metrics
        json_message+="}"   # reports
      json_message+="]"   # reports

    json_message+="}"

    # Escape all 'escape characters' which could have been passed as arguments.
    # If we don't do this, the JSON string can be invalid.
    json_message=${json_message//\\/\\\\}
}

send_json_message()
{
    local http_code
    local curl_error_code
    
    http_code=$(curl -X POST -w "%{http_code}" -o /dev/null -s --connect-timeout "${PERCONA_SEND_TIMEOUT}" --header 'Content-Type: application/json' --location "${PERCONA_TELEMETRY_URL}" --data "${json_message}")
    curl_error_code=$?

    if [[ ${curl_error_code} -ne 0 ]]; then
        return 1
    fi
    if [[ "${http_code}" -ge 400 ]] && [[ "${http_code}" -lt 600 ]]; then
        return 1
    fi

    return 0
}

# Check options passed in.
while getopts "h f:v:s:d:i:j:u:t:" OPTION
do
    case ${OPTION} in
        h)
            usage
            exit_script 1
            ;;
        f)
            PERCONA_PRODUCT_FAMILY=${OPTARG}
            ;;
        v)
            PERCONA_PRODUCT_VERSION=${OPTARG}
            ;;
        s)
            PERCONA_OPERATING_SYSTEM=${OPTARG}
            ;;
        d)
            PERCONA_DEPLOYMENT_METHOD=${OPTARG}
            ;;
        i)
            PERCONA_INSTANCE_ID=${OPTARG}
            ;;
        j)
            PERCONA_TELEMETRY_CONFIG_FILE_PATH=${OPTARG}
            ;;
        u)
            PERCONA_TELEMETRY_URL=${OPTARG}
            ;;
        t)
            PERCONA_SEND_TIMEOUT=${OPTARG}
            ;;
        ?)
            exit 0
            ;;
    esac
done

read_telemetry_config_file
check_telemetry_config

detect_operating_system

# Validate and update setup
validate_args

collect_data_for_report

# Construct the full message
create_json_message
# echo "${json_message}"

check_if_config_file_writable || exit_script 1

# Send the json message
if ! send_json_message; then
    save_config
    exit_script 1
fi

mark_product_as_reported

# Perform clean up and exit.
exit_script 0
