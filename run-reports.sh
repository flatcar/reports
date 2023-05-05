#!/bin/bash

set -euo pipefail

: ${SCRIPTS:='../../scripts/main'}
: ${GENTOO:='../../gentoo/master'}
# I'm usually running reports on Friday, but reports should be based
# on state of things from Thursday, thus 1 day ago. Also the diff is
# made against the state from a week before, also from Thursday, thus
# 8 days ago.
: ${DATE:="$(date --date='1 day ago' '+%F')"}
: ${PREV_DATE:="$(date --date='8 days ago' '+%F')"}
: ${RERUN:=}

CFWG="$(dirname "${0}")/compare-flatcar-with-gentoo"

fail() {
    printf '%s\n' "${*}" >/dev/stderr
    exit 1
}

if [[ "${PREV_DATE}" != '-' ]] && [[ ! -e "${PREV_DATE}/json" ]]; then
    fail "no JSON data for ${PREV_DATE}"
fi

s="${SCRIPTS}"
g="${GENTOO}"

# data variables:
# 0 - var name
# rest - paths passed to git log
scripts_data=(
    s
    sdk_container/src/third_party/coreos-overlay/
    sdk_container/src/third_party/portage-stable/
)

gentoo_data=(
    g
    '.'
)

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
    for repo in scripts gentoo; do
        data_var_name="${repo}_data"
        declare -n data_ref="${data_var_name}"
        repo_path_var_name="${data_ref[0]}"
        declare -n repo_path_ref="${repo_path_var_name}"
        wanted_hash=''
        log_paths=( "${data_ref[@]:1}" )
        # Note that commit_date here is only the date, no time.
        while read -r commit_date commit_hash; do
            commit_unix_date=$(date --date "${commit_date}" '+%s')
            if [[ "${unix_date}" -ge "${commit_unix_date}" ]]; then
                wanted_hash="${commit_hash}"
                break
            fi
        done < <(git -C "${repo_path_ref}" log --pretty=format:'%cd %H' --date='short-local' -- "${log_paths[@]}")
        if [[ -z "${wanted_hash}" ]]; then
            fail "Could not find a commit in ${repo} from ${DATE} or earlier"
        fi
        repo_tmp_path="${PWD}/$(mktemp --directory "./rr-${repo}-XXXXXXXXXX")"
        branch="rr/for-${DATE}"
        git -C "${repo_path_ref}" worktree add --quiet -b "${branch}" "${repo_tmp_path}" "${wanted_hash}"
        printf -v repo_path_escaped '%q' "${repo_path_ref}"
        printf -v repo_tmp_path_escaped '%q' "${repo_tmp_path}"
        printf -v branch_escaped '%q' "${branch}"
        traps="git -C ${repo_path_escaped} worktree remove ${repo_tmp_path_escaped}; git -C ${repo_path_escaped} branch --quiet -D ${branch_escaped}; ${traps}"
        trap "${traps}" EXIT
        repo_path_ref="${repo_tmp_path}"
        unset -n repo_path_ref data_ref
    done
fi

SCRIPTS="${s}" GENTOO="${g}" WORKDIR="${DATE}/wd" KEEP_WORKDIR=x "${CFWG}" >"${DATE}/txt"

SCRIPTS="${s}" GENTOO="${g}" JSON=x WORKDIR="${DATE}/wd" KEEP_WORKDIR=x "${CFWG}" >"${DATE}/json"

if [[ "${PREV_DATE}" != '-' ]]; then
    output=()
    prev_json="${PREV_DATE}/json"
    this_json="${DATE}/json"
    for group in 'general' 'portage-stable' 'coreos-overlay' 'automation'; do
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
