#!/usr/bin/env bash

set -eu

if ! [ -f commit-list ]; then
    echo "Run this script in the directory containing the 'commit-list' file." >&2
    exit 1
fi

if ! [ -d commits -a -d commit-pulls ]; then
    echo "There should be 'commits' and 'commit-pulls' directories." >&2
    echo "Did you run 'fetch-commits.sh'?" >&2
    echo "See README.md for details." >&2
    exit 1
fi

if ! [ -d pulls -a -d reviews ]; then
    echo "There should be 'pulls', and 'reviews' directories." >&2
    echo "Did you run 'fetch-pulls.sh'?" >&2
    echo "See README.md for details." >&2
    exit 1
fi

if ! [ -f trusted.json ]; then
    echo "Trusted auditors file 'trusted.json' doesn't exist." >&2
    exit 1
fi

# These initial indexing steps could winnow out a lot of data, since
# the GitHub API results are pretty verbose, and the final step
# doesn't actually need most of that. But we are not really limited by
# performance, and it's nice to have all the data we could possibly
# want ready at hand in the final step.

# Map each commit's SHA to its data.
jq --slurp 'INDEX(.sha)' commits/* \
> commits.json

# Map each pull request's number to its data.
jq --slurp 'INDEX(.number)' pulls/* \
> pulls.json   

# Map each pull request number to an array of its reviews.
( cd reviews && jq '{ pull: input_filename, reviews: . }' * )   \
| jq --slurp 'INDEX(.pull)'                                     \
> reviews.json

# Provide a default empty set of overrides, if the user didn't create
# any themselves.
if ! [ -f commit-pulls-overrides.json ]; then
    echo '{}' > commit-pulls-overrides.json
fi

# For each commit, determine:
# - the pull request by which it was merged
# - its author
# - reviewers who marked it as approved
# - who ultimately merged the PR
#
# From among those parties, extract the set of trusted auditors who
# played those roles, if any.
#
# Print as tab-separated values, preserving the commit order from commit-list.
jq --raw-input . commit-list \
| jq --slurp                                            \
   --slurpfile commits commits.json                     \
   --slurpfile pulls pulls.json                         \
   --slurpfile reviews reviews.json                     \
   --slurpfile commit_pulls commit-pulls.json           \
   --slurpfile overrides commit-pulls-overrides.json    \
   --argjson trusted "$(cat trusted.json)"              \
   --raw-output                                         \
   '
    # The commit list comes in from `jq --raw-input .` as a single
    # array of strings, in reverse chronological order. We want to
    # produce a stream of entries in chronological order, so reverse
    # and unpack the array.
    reverse | .[]
    # --slurpfile wraps the file contents in an array,
    # which I always forget to look inside, so just take
    # care of doing that up front.
    | $commits[0] as $commits
    | $pulls[0] as $pulls
    | $reviews[0] as $reviews

    # Multiplying objects in jq does exactly the kind
    # of overriding we want for commit-pulls-overrides.json.
    | ($commit_pulls[0] * $overrides[0]) as $commit_pulls
    | $commits[.]
    | ($commit_pulls[.sha].pulls) as $pull_numbers
    | {
        pull: ($pull_numbers[0] // "none"),
        sha,
        author: (.author.login // (.commit.author.name + " (non-GitHub)")),
        approvers: [ $pull_numbers[] | tostring
                     | $reviews[.].reviews[]
                     | select(.state == "APPROVED")
                     | .user.login
                   ]
                   | unique,
        mergers: [ $pull_numbers[] | tostring | $pulls[.].merged_by.login ] | unique,
      }
    | ( .vetters = ( [ .author, .mergers[], .approvers[] | select(in($trusted)) ] | unique ))
    | "\(.pull)\t\(.sha)\t\(.author)\t\(.approvers | join(","))\t\(.mergers | join(","))\t\(.vetters | join(","))"
   ' \
   > mergers-and-approvers.tsv

