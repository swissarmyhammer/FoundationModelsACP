# ``acp_generate``

@Metadata {
  @DisplayName("acp-generate")
}

A code-generation tool that reads the vendored Agent Client Protocol JSON
schema and emits the corresponding Swift types into
`Sources/FoundationModelsACP/Generated`. Run it with `swift run acp-generate`
whenever the schema changes to regenerate identifiers, models, unions, and the
method table.
