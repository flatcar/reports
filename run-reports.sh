#!/bin/bash

set -euo pipefail

: ${COREOS_OVERLAY:='../coreos-overlay/main'}
: ${PORTAGE_STABLE:='../portage-stable/main'}
: ${GENTOO:='../gentoo'}
: ${CFWG:='../flatcar-build-scripts/compare-flatcar-with-gentoo'}
# I'm usually running reports on Friday, but reports should be based
# on state of things from Thursday, thus 1 day ago. Also the diff is
# made against the state from a week before, also from Thursday, thus
# 8 days ago.
: ${DATE:="$(date --date='1 day ago' '+%F')"}
: ${PREV_DATE:="$(date --date='8 days ago' '+%F')"}
: ${RERUN:=}

fail() {
    printf '%s\n' "${*}" >/dev/stderr
    exit 1
}

if [[ "${PREV_DATE}" != '-' ]] && [[ ! -e "${PREV_DATE}/json" ]]; then
    fail "no JSON data for ${PREV_DATE}"
fi

co="${COREOS_OVERLAY}"
ps="${PORTAGE_STABLE}"
g="${GENTOO}"

if [[ -z "${RERUN}" ]]; then
    if [[ -e "${DATE}" ]]; then
        rm -rf "${DATE}.old"
        mv "${DATE}"{,.old}
    fi

    mkdir "${DATE}"

    # Here we create a separate worktree and we go backward in commits
    # log to find the latest commit from the specified DATE, so we can
    # reset the repo state to that commit. This will be passed to the
    # compare-flatcar-with-gentoo script.
    unix_date="$(date --date "${DATE}" '+%s')"
    traps=':'
    for pair in "portage-stable:ps" "coreos-overlay:co" "gentoo:g"; do
        repo="${pair%%:*}"
        var_name="${pair#*:}"
        path="${!var_name}"
        wanted_hash=''
        # Note that commit_date here is only the date, no time.
        while read -r commit_date commit_hash; do
            commit_unix_date=$(date --date "${commit_date}" '+%s')
            if [[ "${unix_date}" -ge "${commit_unix_date}" ]]; then
                wanted_hash="${commit_hash}"
                break
            fi
        done < <(git -C "${path}" log --pretty=format:'%cd %H' --date='short-local')
        if [[ -z "${wanted_hash}" ]]; then
            fail "Could not find a commit in ${repo} from ${DATE} or earlier"
        fi
        repo_tmp_path="${PWD}/$(mktemp --directory "./rr-${repo}-XXXXXXXXXX")"
        branch="rr/for-${DATE}"
        git -C "${path}" worktree add --quiet -b "${branch}" "${repo_tmp_path}"
        git -C "${repo_tmp_path}" reset --quiet --hard "${wanted_hash}"
        declare -n var_ref="${var_name}"
        var_ref="${repo_tmp_path}"
        unset -n var_ref
        traps+="; git -C '${path}' worktree remove '${repo_tmp_path}'; git -C '${path}' branch --quiet -D '${branch}'"
        trap "${traps}" EXIT
    done
fi

COREOS_OVERLAY="${co}" PORTAGE_STABLE="${ps}" GENTOO="${g}" WORKDIR="${DATE}/wd" KEEP_WORKDIR=x "${CFWG}" >"${DATE}/txt"

COREOS_OVERLAY="${co}" PORTAGE_STABLE="${ps}" GENTOO="${g}" JSON=x WORKDIR="${DATE}/wd" KEEP_WORKDIR=x "${CFWG}" >"${DATE}/json"

if [[ "${PREV_DATE}" != '-' ]]; then
    output=()
    prev_json="${PREV_DATE}/json"
    this_json="${DATE}/json"
    for group in 'general' 'portage-stable' 'coreos-overlay'; do
        group_keys=()
        while read -r; do
            group_keys+=("${REPLY}")
        done < <(jq ".[\"${group}\"] | keys_unsorted" "${this_json}" |
                     head -n -1 |
                     tail -n +2 |
                     sed -e 's/^\s*"\([^"]*\).*/\1/g')
        diff_names=()
        diff_values=()

        for k in "${group_keys[@]}"; do
            filter=".[\"${group}\"][\"${k}\"]"
            prev_value="$(jq "${filter}" "${prev_json}")"
            this_value="$(jq "${filter}" "${this_json}")"

            if [[ "${prev_value}" -ne "${this_value}" ]]; then
                diff_names+=( "${k}" )
                diff_value=$((this_value - prev_value))
                if [[ "${diff_value}" -gt 0 ]]; then
                    diff_value="+${diff_value}"
                fi
                diff_values+=( "${diff_value} (from ${prev_value} to ${this_value})" )
            fi
        done

        if [[ "${#diff_names[@]}" -gt 0 ]]; then
            output+=("${group}:")
            for i in $(seq 0 $(("${#diff_names[@]}" - 1))); do
                output+=(" ${diff_names[${i}]}: ${diff_values[${i}]}")
            done
            output+=('')
        fi
    done
    if [[ "${#output[@]}" -gt 0 ]] && [[ -z "${output[-1]}" ]]; then
        unset output[-1]
    fi
    printf '%s\n' "${output[@]}" >"${DATE}/diff-with-${PREV_DATE}"
fi
