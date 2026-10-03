# Instructions for agents working on msl

## Reporting findings

Present research, investigations and test results in three parts, in this order:

1. **Findings.** Facts only, one per bullet. No recommendations, options or opinions mixed in.
2. **Proposal.** What you recommend doing, and why, based on the findings.
3. **Proof.** The evidence behind the findings: commands run and their output (trimmed), measurements, file and line references, and documentation links.

Don't interleave the three, don't end with a menu of options, and don't add summaries or recaps around them.

## Commit messages

Write commit messages like a human developer, not like release notes.

- Describe the reason for the change and its outcome, not a file-by-file summary.
- Prefer short, natural, imperative subject lines, under about 60 characters when practical.
- Don't enumerate every modified file, function or implementation detail.
- Add a body only when the motivation, a tradeoff or non-obvious context matters. In it, explain why the change was needed rather than repeating the diff.
- Match the tone and style of recent commits in this repository.

Prefer:

- Prevent duplicate webhook deliveries
- Preserve filters when navigating back
- Retry failed uploads to avoid transient drops
- Keep users signed in after token refresh

Avoid:

- Implement enhanced webhook handling
- Update authentication logic
- Improve error handling
- Refactor cache system
- This commit updates...
- Exhaustive bullet lists that restate the diff
- Vague AI-style wording such as robust, comprehensive, seamless or streamlined

## Debugging

When a fix starts turning into a chain of workarounds, stop patching symptoms and look one layer higher. Ask which assumption in our own design lets the symptom happen at all, and fix it there.

- Two or three fixes in a row for the same kind of failure (a lost byte, a hang, a race) usually means the cause is above the code being patched: a protocol that relies on behaviour the layer below doesn't guarantee, a lifecycle the code doesn't own, or a check that hides the real failure.
- Before adding a retry, timeout, delay or fallback, say what it compensates for and why that can't be fixed where it starts.
- Name the layer and the assumption in the findings, not just the symptom and the patch.
