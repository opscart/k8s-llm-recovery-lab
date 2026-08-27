# Invalid Cloud CPU Runs

`1b-emptydir-invalid.csv` was rejected because the Ollama model directory was backed by `emptyDir`, causing the model artifact to disappear after each pod replacement.

The run therefore measured runtime recovery followed by failed inference requests (`model not found`) rather than functional LLM recovery.

It is retained only as methodology/debugging evidence and must not be included in statistical analysis.
