# How to map a project

1. In your project's working directory, ask an agent with the `strata` skill to trace one request from its entry point to storage. Include queues and downstream services where they affect that request.
2. Ask the agent to write a `kind: architecture` manifest under `~/.strata/sims`. Have it include paths to the handlers and consumers you read.
3. Run `strata validate ~/.strata/sims/my-project.yaml`. Fix errors, then open the map with `strata open my-project`.
4. Follow the request in Strata. Slow one dependency and record what changes in a node note.

Strata keeps the manifest and notes on this Mac. Its window is excluded from screen sharing. Store project details in `~/.strata` to keep them out of the project's repository.

Use the [[System design/Checklist|system design checklist]] to decide which failure to try.
