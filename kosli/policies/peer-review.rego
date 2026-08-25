package policy

# Peer review passes when the pull request behind the commit exists and was approved either
# by two distinct people, or by one approver who did not write the code - Kosli's "never
# alone" review control: https://github.com/kosli-dev/control-actions.
#
# Evaluated with:
#   kosli evaluate input --input-file peer-review.json --policy kosli/policies/peer-review.rego
#
# The verdict is recorded against the `peer-review` control with:
#   kosli attest decision --control peer-review --compliant=<allow>
#
# peer-review.json is the same data the `peer-review` custom attestation carries - see
# scripts/peer_review_attestation.py.
default allow := false

has_pull_request if input.pull_request_url != null

sufficient_review if input.distinct_approvers >= 2
sufficient_review if input.independent_approval == true

allow if {
	has_pull_request
	sufficient_review
}

violations contains "no pull request found for this commit" if not has_pull_request

violations contains "requires two distinct approvers, or one approver who did not write the code" if {
	has_pull_request
	not sufficient_review
}
