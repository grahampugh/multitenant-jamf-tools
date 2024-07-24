#!/bin/bash

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#
# Copyright (c) 2018 Jamf.  All rights reserved.
#
#       Redistribution and use in source and binary forms, with or without
#       modification, are permitted provided that the following conditions are met:
#               * Redistributions of source code must retain the above copyright
#                 notice, this list of conditions and the following disclaimer.
#               * Redistributions in binary form must reproduce the above copyright
#                 notice, this list of conditions and the following disclaimer in the
#                 documentation and/or other materials provided with the distribution.
#               * Neither the name of the Jamf nor the names of its contributors may be
#                 used to endorse or promote products derived from this software without
#                 specific prior written permission.
#
#       THIS SOFTWARE IS PROVIDED BY JAMF SOFTWARE, LLC "AS IS" AND ANY
#       EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
#       WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
#       DISCLAIMED. IN NO EVENT SHALL JAMF SOFTWARE, LLC BE LIABLE FOR ANY
#       DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
#       (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
#       LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
#       ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
#       (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
#       SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
#
# What is scoped to my Computer Groups?
#
# In this script we will utilize the Jamf Pro API to determine what Policies, Configuration
# Profiles, Restricted Software, Mac App Store Apps and eBooks are assigned to your
# Computer Groups.
#
# OBJECTIVES
#       - Create a list of all Smart Groups
#       - Provide a list of what is scoped to each Smart Group
#
# For more information, visit https://github.com/kc9wwh/JamfProGroupsScoped
#
#
# Written by: Joshua Roskos | Jamf
#
# Created On: October 2nd, 2017
# Updated On: February 1st, 2024 (added support for Sonoma and bearer token)
# 
# This version adapted for use with multiple Jamf Pro clients by Graham Pugh
#
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# SETUP FOR MULTITENANT-JAMF-TOOLS
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# source the get-token.sh file
# TIP for Visual Studio Code - Add Custom Arg '-x' to the Shellcheck extension settings
source "get-token.sh"

# reduce the curl tries
max_tries_override=2

# set instance list type
instance_list_type="ios"

# obtain current user for exporting file
currentUser=$(/usr/bin/stat -f%Su /dev/console)

if [[ ! -d "${this_script_dir}" ]]; then
    echo "ERROR: path to repo ambiguous. Aborting."
    exit 1
fi

## MAIN BODY

# -------------------------------------------------------------------------
# Command line options (presets to avoid interaction)
# -------------------------------------------------------------------------

# Command line override for the above settings
while [[ "$#" -gt 0 ]]; do
    key="$1"
    case $key in
        -il|--instance-list)
            shift
            instance_list_file="$1"
        ;;
        -i|--instance)
            shift
            chosen_instance="$1"
        ;;
        -a|--all)
            all_instances=1
        ;;
        -v|--verbose)
            verbose=1
        ;;
        -h|--help)
            usage
            exit
        ;;
    esac
    # Shift after checking all the cases to get the next option
    shift
done
echo


# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# FUNCTIONS
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# getBearerToken() {
# 	response=$(curl -s -u "$jamfUser":"$jamfPass" "$jamfURL"/api/v1/auth/token -X POST)
# 	access_token=$(echo "$response" | plutil -extract token raw -)
# }

## Function Format - findScopedObjects
## $1: Object Type (Policy, Configuration Profile, Restricted Software, Mac App Store App, eBook)
## $2: xpath/XML Tree - Top Level Only (policy, os_x_configuration_profile, restricted_software, mac_application, ebook)
findScopedObjects() {
    local object_printname="$1"
    local api_xml_object="$2"
    api_object_type=$( get_api_object_type "$api_xml_object" )

    echo "Retrieving List of All $object_printname IDs..."
    unset objectIDs

    # send request
    curl_url="$jss_url/JSSResource/$api_object_type"
    curl_args=("--request")
    curl_args+=("GET")
    curl_args+=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    # cat "$curl_output_file"


    objectIDs=$(
        xmllint --xpath "//$api_xml_object/id" \
        "$curl_output_file" 2>/dev/null \
        | sed 's|><|>,<|g' | sed 's|<[^>]*>||g' | tr "," "\n"
    )

    while read -r i; do
        echo "Retrieving $object_printname ID $i's' Data..."

        # send request
        curl_url="$jss_url/JSSResource/$api_object_type/id/$i"
        curl_args=("--request")
        curl_args+=("GET")
        curl_args+=("--header")
        curl_args+=("Accept: application/xml")
        send_curl_request

        objectName=$(/usr/bin/xmllint --xpath "//$api_xml_object/general/name/text()" "$curl_output_file" 2>/dev/null)

        if [[ "$object_printname" == "Policy" ]]; then
            ## Check if is a Jamf Remote Policy
            echo "Checking if '$objectName' is a Jamf Remote Policy..."
            if [[ $objectName == $(/usr/bin/grep -qe -B1 '[0-9]+-[0-9]{2}-[0-9]{2} at [0-9]{1,2}:[0-9]{2,2} [AP]M \| .* \| .*' <<< "$objectName" 2>&1) ]]; then
                ## This is a Jamf Remote Policy
                ## Setting policy name in array to "JamfRemotePolicy-Ignore"
                echo "    '$objectName' is a Jamf Remote policy"
                continue
            else
                ## This is NOT a Casper Remote Policy
                ## Storing Policy Name and Grabbing Scope Data
                echo "    '$objectName' is a standard policy"

                ## Extract Scoped Computer Group ID(s)
                unset grpID
                grpIDs=$(
                    xmllint --xpath "//$api_xml_object/scope/computer_groups/computer_group/id" \
                    "$curl_output_file" 2>/dev/null \
                    | sed 's|><|>,<|g' | sed 's|<[^>]*>||g' | tr "," "\n"
                )

                if [[ ! $grpIDs ]]; then
                    echo "No Computer Groups Scoped in $object_printname ${objectIDs[$i]}..."
                else
                    echo "Computer Groups found for $1 ${objectIDs[$i]}..."
                    while read -r id; do
                        grpName=$(xmllint --xpath "//$api_xml_object/scope/computer_groups/computer_group[id=$id]/name/text()" "$curl_output_file")
                        echo "    Group ID: $id - Group Name: $grpName" # TEMP
                        declare -a "compGrp${id}=($grpName)"
                        # eval compGrp$id+=\(\"$objectName \($object_printname\)\"\)
                    done <<< "${grpIDs[@]}"

                fi
            fi
        else
            # cat "$curl_output_file" # TEMP
            echo "    Checking for groups in '$objectName' ($i)"
            unset grpID
            grpIDs=$(
                xmllint --xpath "//$api_xml_object/scope/computer_groups/computer_group/id" \
                "$curl_output_file" 2>/dev/null \
                | sed 's|><|>,<|g' | sed 's|<[^>]*>||g' | tr "," "\n"
            )

            if [[ ! $grpIDs ]]; then
                echo "    No Computer Groups Scoped in '$objectName' ($i)"
            else
                echo "    Computer Groups found for '$objectName' ($i):"
                while read -r gid ; do
                    grpName=$(xmllint --xpath "//$api_xml_object/scope/computer_groups/computer_group[id=$gid]/name/text()" "$curl_output_file")
                    declare -a "compGrp${gid}=($grpName)"
                    echo "        $grpName (${gid})" # TEMP
                done <<< "${grpIDs}"
               

                # while read -r id; do
                #     grpName=$(xmllint --xpath "//$api_xml_object/scope/computer_groups/computer_group[id=$id]/name/text()" "$curl_output_file")
                #     echo "    Group ID: $id - Group Name: $grpName" # TEMP
                #     # eval compGrp$id+=\(\"$objectName \($object_printname\)\"\)
                # done <<< "${grpIDs[@]}"
                # tempthing="compGrp$id"
                # echo "    TEMP THING: ${!tempthing[*]}" # TEMP
            fi
        fi
        sleep .3
    done <<< "${objectIDs[@]}"
}

getUsedGroups() {
    # determine jss_url
    set_credentials "$jss_instance"
    jss_url="$jss_instance"
    # send request
    curl_url="$jss_url/JSSResource/computergroups"
    curl_args=("--request")
    curl_args+=("GET")
    curl_args+=("--header")
    curl_args+=("Accept: application/xml")
    send_curl_request

    ## Retrieve & Extract Computer Group IDs/Names & Build Array
    compGrpSize=$(/usr/bin/xmllint --xpath "//computer_groups/size/text()" "$curl_output_file" 2>/dev/null)

    echo
    cat "$curl_output_file"
    echo

    ## Error handling for computer group data and size
    if [[ $compGrpSize == 0 ]] ; then
    	echo "ERROR: No groups were downloaded.  Please verify connection to the JSS."
    	exit 2
    fi

    if grep "Unauthorized" "$curl_output_file"; then
    	echo "ERROR: JSS rejected the API credentials.  Please double-check the script and run again."
    	exit 1
    fi

    index=0
    declare -a compGrpNames
    declare -a compGrpIDs
    while [[ $index -lt $compGrpSize ]]; do
        element=$((index+1))
        compGrpName=$(/usr/bin/xmllint --xpath "//computer_groups/computer_group[${element}]/name/text()" "$curl_output_file" 2>/dev/null)
        compGrpID=$(/usr/bin/xmllint --xpath "//computer_groups/computer_group[${element}]/id/text()" "$curl_output_file" 2>/dev/null)
        echo "    Computer Group ID: $compGrpID"  # TEMP
        echo "    Computer Group Name: $compGrpName"  # TEMP
        compGrpNames[index]="$compGrpName"
        compGrpIDs[index]="$compGrpID"
        ((index++))
    done

    echo 
    echo

    ## Check Policies, Configuration Profiles, Restircted Software and Mac App Store Apps
    # findScopedObjects "Policy" "policy"
    findScopedObjects "Configuration Profile" "os_x_configuration_profile"
    # findScopedObjects "Restricted Software" "restricted_software"
    # findScopedObjects "Mac App Store App" "mac_application"
    # findScopedObjects "eBook" "ebook"

    # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
    # BUILD HTML REPORT
    # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

    reportDate=$(/bin/date "+%Y-%m-%d %H%M%S")
    reportName="/Users/${currentUser}/Desktop/Jamf Pro Computer Group Report - $reportDate.html"
    echo "<html>
    <head>
    <title>Jamf Pro Computer Groups Report - $reportDate</title>
    </head>
    <body>
    <h1>Jamf Pro Computer Groups Report</h1>
    <i>Report Date: $reportDate<br/>Jamf Pro server: $jss_url</i>
    <hr/>
    <p/>" > "$reportName"
    for (( x = 0 ; x < ${#compGrpNames[@]} ; x++ )); do
        echo "    Group Name: ${compGrpNames[$x]}" # TEMP
        echo "<b>${compGrpNames[$x]}</b><br/><ul>" >> "$reportName"
        groupID="${compGrpIDs[$x]}"
        echo "    Group ID: $groupID" # TEMP
        # declare -n localGroupIDarray="compGrp$groupID"
        eval "localGroupIDarray=( \${compGrp${groupID}[@]} )" 
        echo "    Group ID Name: $localGroupIDarray" # TEMP
        echo "    Group ID List: ${localGroupIDarray[*]}" # TEMP
        for (( y = 0 ; y < ${#localGroupIDarray[@]} ; y++ )); do
            echo "<li>${localGroupIDarray[$y]}</li>" >> "$reportName"
        done
        echo "</ul><p/>" >> "$reportName"
    done
    echo "</body>
    </html>" >> "$reportName"

    open "$reportName"

}

# ------------------------------------------------------------------------------------
# 1. Ask for the instance list, show list, ask to apply to one, multiple or all
# ------------------------------------------------------------------------------------

# Set default instance list
default_instance_list="prd"

# select the instances that will be changed
choose_destination_instances

# get specific instance if entered
if [[ $chosen_instance ]]; then
    jss_instance="$chosen_instance"
    echo "Generating report on $jss_instance..."
    getUsedGroups
else
    for instance in "${instance_choice_array[@]}"; do
        jss_instance="$instance"
        echo "Generating report on $jss_instance..."
        getUsedGroups
    done
fi

echo 
echo "Finished"
echo
