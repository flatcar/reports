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
    unix_date="$(date --date "${DATE} next day" '+%s')"
    traps=':'
    for repo in scripts gentoo; do
        data_var_name="${repo}_data"
        declare -n data_ref="${data_var_name}"
        repo_path_var_name="${data_ref[0]}"
        declare -n repo_path_ref="${repo_path_var_name}"
        wanted_hash=''
        log_paths=( "${data_ref[@]:1}" )
        tmp_paths=()
        tmp_repos=()
        tmp_hashes=()
        tmp_dates=()
        for log_path in "${log_paths[@]}"; do
            commit_date=''
            commit_hash=''
            while read -r line; do
                if [[ -z "${commit_date}" ]]; then
                    commit_date="${line}"
                else
                    commit_hash="${line}"
                fi
            done < <(git -C "${repo_path_ref}" log -1 --until="${unix_date}" --pretty=format:'%cD%n%H%n' -- "${log_path}")
            if [[ -z "${commit_hash}" ]]; then
                fail "Could not find a commit in ${repo} from ${DATE} or earlier for path '${log_path}'"
            fi
            path_suffix=''
            if [[ "${log_path}" != '.' ]]; then
                path_suffix="-$(basename "${log_path}")"
            fi
            branch="rr/for-${DATE}${path_suffix}-${RANDOM}"
            repo_tmp_path="${PWD}/$(mktemp --directory "./rr-${repo}${path_suffix}-XXXXXXXXXX")"
            git -C "${repo_path_ref}" worktree add --quiet -b "${branch}" "${repo_tmp_path}" "${commit_hash}"
            printf -v repo_path_escaped '%q' "${repo_path_ref}"
            printf -v repo_tmp_path_escaped '%q' "${repo_tmp_path}"
            printf -v branch_escaped '%q' "${branch}"
            traps="git -C ${repo_path_escaped} worktree remove ${repo_tmp_path_escaped}; git -C ${repo_path_escaped} branch --quiet -D ${branch_escaped}; ${traps}"
            trap "${traps}" EXIT
            tmp_paths+=("${log_path}")
            tmp_repos+=("${repo_tmp_path}")
            tmp_hashes+=("${commit_hash}")
            tmp_dates+=("${commit_date}")
        done
        if [[ ${#tmp_repos[@]} -ne ${#tmp_paths[@]} ]]; then
            fail "Inconsistent number of repos for ${repo}"
        fi
        if [[ ${#tmp_hashes[@]} -ne ${#tmp_paths[@]} ]]; then
            fail "Inconsistent number of hash info entries for ${repo}"
        fi
        if [[ ${#tmp_dates[@]} -ne ${#tmp_paths[@]} ]]; then
            fail "Inconsistent number of date info entries for ${repo}"
        fi
        if [[ ${#tmp_paths[@]} -eq 1 ]]; then
            repo_path_ref="${tmp_repos[0]}"
        else
            fake_repo_path="${PWD}/$(mktemp --directory "./rr-${repo}-fake-XXXXXXXXXX")"
            printf -v fake_repo_path_escaped '%q' "${fake_repo_path}"
            traps="rmdir ${fake_repo_path_escaped}; ${traps}"
            trap "${traps}" EXIT
            idx=0
            while [[ ${idx} -lt ${#tmp_paths[@]} ]]; do
                path=${tmp_paths[${idx}]}
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
                    ln -sT "${tmp_repos[${idx}]}/${path}" "${fake_full_path}"
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
