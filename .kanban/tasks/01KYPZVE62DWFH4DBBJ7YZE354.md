---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: Fix pre-existing DocC warnings on acp-test-agent/acp-generate catalogs
---
`swift package generate-documentation` emits 2 warnings, confirmed pre-existing (present both before and after the M9 ^p68s7v7 changes — verified via git stash comparison):

```
warning: No valid content was found in this file
A '.' file should contain a top-level directive ('Tutorials', 'Tutorial', or 'Article') and valid child content. Only '.md' files support content without a top-level directive
 --> ../../../../../..:1:1-5:2
1 + # ``acp_test_agent``
2 +
3 + @Metadata {
4 +   @DisplayName("acp-test-agent")
5 + }
```

Same warning for `acp_generate`. Both are the DocC catalog root pages for the `acp-test-agent` and `acp-generate` executable targets — they carry only a title + `@Metadata` block with no top-level directive (`Article`, `Tutorial`, etc.), so DocC treats them as empty. Fix by adding a minimal `@Article`-wrapped body (or equivalent) to each catalog's landing page so `swift package generate-documentation` runs warning-free.

Found during independent verification of ^p68s7v7 (M9). Not introduced by that task — unrelated to its scope — filed separately so the build can eventually reach true zero-warnings on DocC. #test-failure