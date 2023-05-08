#!/bin/bash

set -euo pipefail

# Thu Apr 13 12:22:25 2023 +0200 - when coreos-overlay and
# portage-stable got merged into scripts. For dates older than this,
# we will use the old coreos-overlay and portage-stable repos.
MERGE_DATE='2023-04-13'
UNIX_MERGE_DATE="$(date --date "${MERGE_DATE}" '+%s')"

# Separate coreos-overlay and portage-stable are used for generating
# reports from dates older before MERGE_DATE.
: ${COREOS_OVERLAY:='../../coreos-overlay/main'}
: ${PORTAGE_STABLE:='../../portage-stable/main'}
# Scripts repo is used for generating reports for dates at or after
# the MERGE_DATE.
: ${SCRIPTS:='../../scripts/main'}
: ${GENTOO:='../../gentoo/master'}
# I'm usually running reports on Friday, but reports should be based
# on state of things from Thursday, thus 1 day ago. Also the diff is
# made against the state from a week before, also from Thursday, thus
# 8 days ago.
: ${DATE:="$(date --date='1 day ago' '+%F')"}
: ${PREV_DATE:="$(date --date='8 days ago' '+%F')"}
: ${RERUN:=}
: ${VERBOSE:=}

CFWG="$(dirname "${0}")/compare-flatcar-with-gentoo"

stderr() {
    printf '%s\n' "${*}" >/dev/stderr
}

fail() {
    stderr "${@}"
    exit 1
}

debug() {
    if [[ -z "${VERBOSE}" ]]; then
        return
    fi
    stderr "$@"
}

if [[ "${PREV_DATE}" != '-' ]] && [[ ! -e "${PREV_DATE}/json" ]]; then
    fail "no JSON data for ${PREV_DATE}"
fi

s="${SCRIPTS}"
g="${GENTOO}"

# data variables:
# 0 - var name
# rest - triples of paths passed to git log, possible git repo to use if date is before MERGE_DATE, and path to get from the old repo
scripts_data=(
    s

    sdk_container/src/third_party/coreos-overlay
    "${COREOS_OVERLAY}"
    '.'

    sdk_container/src/third_party/portage-stable
    "${PORTAGE_STABLE}"
    '.'
)

gentoo_data=(
    g

    '.'
    '-'
    '.'
)

if [[ -z "${RERUN}" ]]; then
    debug "Regenerating work data"
    if [[ -e "${DATE}" ]]; then
        debug "Saving old ${DATE} as ${DATE}.old"
        rm -rf "${DATE}.old"
        mv "${DATE}"{,.old}
    fi

    mkdir "${DATE}"

    # Here we create a separate worktree and we go backward in commits
    # log to find the latest commit from the specified DATE, so we can
    # reset the repo state to that commit. This will be passed to the
    # compare-flatcar-with-gentoo script.
    unix_date="$(date --date "${DATE} next day" '+%s')"
    traps=':'
    for repo in scripts gentoo; do
        debug "Setting up ${repo}"
        data_var_name="${repo}_data"
        declare -n data_ref="${data_var_name}"
        repo_path_var_name="${data_ref[0]}"
        declare -n repo_path_ref="${repo_path_var_name}"
        wanted_hash=''
        rest=( "${data_ref[@]:1}" )
        tmp_paths=()
        tmp_repos=()
        tmp_src_paths=()
        tmp_hashes=()
        tmp_dates=()
        idx=0
        while [[ $((idx + 2)) -lt "${#rest[@]}" ]]; do
            #for log_path in "${log_paths[@]}"; do
            target_path="${rest[$((idx + 0))]}"
            old_repo="${rest[$((idx + 1))]}"
            log_path_old_repo="${rest[$((idx + 2))]}"
            idx=$((idx + 3))
            commit_date=''
            commit_hash=''
            log_repo="${repo_path_ref}"
            log_path="${target_path}"
            repo_name_for_path="${repo}"
            if [[ "${old_repo}" != '-' ]]; then
                actual_unix_date="$(date --date "${DATE}" '+%s')"
                if [[ "${actual_unix_date}" -lt "${UNIX_MERGE_DATE}" ]]; then
                    debug "Will use the old, pre-submodules merge repo"
                    log_repo="${old_repo}"
                    log_path="${log_path_old_repo}"
                    repo_name_for_path="${target_path##*/}"
                fi
            fi
            while read -r line; do
                if [[ -z "${commit_date}" ]]; then
                    commit_date="${line}"
                else
                    commit_hash="${line}"
                fi
            done < <(git -C "${log_repo}" log -1 --until="${unix_date}" --pretty=format:'%cD%n%H%n' -- "${log_path}")
            if [[ -z "${commit_hash}" ]]; then
                fail "Could not find a commit in ${log_repo} from ${DATE} or earlier for path '${log_path}'"
            fi
            debug "Found commit ${commit_hash} for ${target_path}"
            path_suffix='-whole-thing'
            if [[ "${log_path}" != '.' ]]; then
                path_suffix="-$(basename "${log_path}")"
            fi
            branch="rr/for-${DATE}${path_suffix}-${RANDOM}"
            repo_tmp_path="${PWD}/$(mktemp --directory "./rr-${repo_name_for_path}${path_suffix}-XXXXXXXXXX")"
            git -C "${log_repo}" worktree add --quiet -b "${branch}" "${repo_tmp_path}" "${commit_hash}"
            printf -v log_repo_escaped '%q' "${log_repo}"
            printf -v repo_tmp_path_escaped '%q' "${repo_tmp_path}"
            printf -v branch_escaped '%q' "${branch}"
            traps="git -C ${log_repo_escaped} worktree remove ${repo_tmp_path_escaped}; git -C ${log_repo_escaped} branch --quiet -D ${branch_escaped}; ${traps}"
            trap "${traps}" EXIT
            tmp_paths+=("${target_path}")
            tmp_repos+=("${repo_tmp_path}")
            tmp_src_paths+=("${log_path}")
            tmp_hashes+=("${commit_hash}")
            tmp_dates+=("${commit_date}")
        done
        if [[ ${#tmp_repos[@]} -ne ${#tmp_paths[@]} ]]; then
            fail "Inconsistent number of repos for ${repo}"
        fi
        if [[ ${#tmp_hashes[@]} -ne ${#tmp_paths[@]} ]]; then
            fail "Inconsistent number of hash info entries for ${repo}"
        fi
        if [[ ${#tmp_src_paths[@]} -ne ${#tmp_paths[@]} ]]; then
            fail "Inconsistent number of source path entries for ${repo}"
        fi
        if [[ ${#tmp_dates[@]} -ne ${#tmp_paths[@]} ]]; then
            fail "Inconsistent number of date info entries for ${repo}"
        fi
        if [[ ${#tmp_paths[@]} -eq 1 ]]; then
            repo_path_ref="${tmp_repos[0]}"
        else
            debug "Setting up fake repo for ${repo}"
            fake_repo_path="${PWD}/$(mktemp --directory "./rr-${repo}-fake-XXXXXXXXXX")"
            printf -v fake_repo_path_escaped '%q' "${fake_repo_path}"
            traps="rmdir ${fake_repo_path_escaped}; ${traps}"
            trap "${traps}" EXIT
            idx=0
            while [[ ${idx} -lt ${#tmp_paths[@]} ]]; do
                path=${tmp_paths[${idx}]}
                debug "Setting up fake git data in the fake repo"
                dot_fake_git_dir="${fake_repo_path}/.fake_git"
                if [[ ! -d "${dot_fake_git_dir}" ]]; then
                    mkdir "${dot_fake_git_dir}"
                    printf -v dot_fake_git_dir_escaped '%q' "${dot_fake_git_dir}"
                    traps="rmdir ${dot_fake_git_dir_escaped}; ${traps}"
                    trap "${traps}" EXIT
                fi
                fake_hash_base="${dot_fake_git_dir}/$(basename "${path}")"
                fake_hash_file="${fake_hash_base}.hash"
                echo "${tmp_hashes[${idx}]}" >"${fake_hash_file}"
                printf -v fake_hash_file_escaped '%q' "${fake_hash_file}"
                traps="rm ${fake_hash_file_escaped}; ${traps}"
                trap "${traps}" EXIT
                fake_date_file="${fake_hash_base}.date"
                echo "${tmp_dates[${idx}]}" >"${fake_date_file}"
                printf -v fake_date_file_escaped '%q' "${fake_date_file}"
                traps="rm ${fake_date_file_escaped}; ${traps}"
                trap "${traps}" EXIT
                debug "Setting up ${path} in the fake repo"
                dir_part=${path%/*}
                prev=''
                rest="${dir_part}"
                while [[ -n "${rest}" ]]; do
                    dir=${rest%%/*}
                    rest=${rest#${dir}}
                    rest=${rest#/}
                    full_dir=${prev}${prev:+/}${dir}
                    prev="${full_dir}"
                    full_path="${fake_repo_path}/${full_dir}"
                    if [[ -e "${full_path}" ]]; then
                        if [[ ! -d "${full_path}" ]]; then
                            fail "${full_path} is not a directory"
                        fi
                    else
                        mkdir "${full_path}"
                        printf -v full_path_escaped '%q' "${full_path}"
                        traps="rmdir ${full_path_escaped}; ${traps}"
                        trap "${traps}" EXIT
                    fi
                done
                fake_full_path="${fake_repo_path}/${path}"
                if [[ -e "${fake_full_path}" ]]; then
                    if [[ ! -h "${fake_full_path}" ]]; then
                        fail "${fake_full_path} is not a symlink"
                    fi
                else
                    ln -sT "${tmp_repos[${idx}]}/${tmp_src_paths[${idx}]}" "${fake_full_path}"
                    printf -v fake_full_path_escaped '%q' "${fake_full_path}"
                    traps="rm ${fake_full_path_escaped}; ${traps}"
                    trap "${traps}" EXIT
                fi
                idx=$((idx + 1))
            done
            repo_path_ref="${fake_repo_path}"
        fi
        unset -n repo_path_ref data_ref
    done
fi

debug "Invoking compare-flatcar-with-gentoo for text files"
SCRIPTS="${s}" GENTOO="${g}" WORKDIR="${DATE}/wd" KEEP_WORKDIR=x "${CFWG}" >"${DATE}/txt"

debug "Invoking compare-flatcar-with-gentoo for JSON files"
SCRIPTS="${s}" GENTOO="${g}" JSON=x WORKDIR="${DATE}/wd" KEEP_WORKDIR=x "${CFWG}" >"${DATE}/json"

if [[ "${PREV_DATE}" != '-' ]]; then
    debug "Generating a diff against ${PREV_DATE}"
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
