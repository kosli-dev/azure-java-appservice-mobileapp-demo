package policy

# Peer review passes when the pull request behind the commit exists and was approved either
# by two distinct people, or by one approver who did not write the code - Kosli's "never
# alone" review control: https://github.com/kosli-dev/control-actions.
#
# Evaluated directly against the data of the trail's own `pull-request` attestation (the one
# `kosli attest pullrequest github` already reports), fetched back with `kosli get
# attestation` - no separate GitHub API call or custom JSON is needed:
#
#   kosli get attestation pull-request --flow order-system-ci --trail "$KOSLI_TRAIL" \
#     --output json | jq '.[0]' > pull-request.json
#   kosli evaluate input --input-file pull-request.json --policy kosli/policies/peer-review.rego
#
# input.pull_requests is the CLI's own shape: a list of
# {url, merged_at, approvers: [{username}], commits: [{author_username}], ...}.
default allow := false

has_pull_request if count(input.pull_requests) > 0

# A commit can be associated with more than one pull request (rare); prefer the merged one,
# since that is the one that actually reached main, falling back to the first if none merged.
merged_prs := [pr | some pr in input.pull_requests; pr.merged_at != null]

pr := merged_prs[0] if count(merged_prs) > 0

pr := input.pull_requests[0] if count(merged_prs) == 0

approvers := {a.username | some a in pr.approvers}

committers := {c.author_username | some c in pr.commits}

sufficient_review if count(approvers) >= 2

sufficient_review if count(approvers - committers) > 0

allow if {
	has_pull_request
	sufficient_review
}

violations contains "no pull request found for this commit" if not has_pull_request

violations contains "requires two distinct approvers, or one approver who did not write the code" if {
	has_pull_request
	not sufficient_review
}
