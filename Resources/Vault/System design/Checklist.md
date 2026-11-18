---
glossaries: [kafka, redis, resilience, queueing]
---
# System design checklist

Pick a single request or event and follow it through the system.

- [ ] Record peak arrival rate, end-to-end timeout, and the first place requests queue.
- [ ] Slow a dependency and check where backpressure reaches callers.
- [ ] Retry a write after a timeout. Verify the idempotency key prevents a duplicate effect.
- [ ] Pause a consumer. Track consumer lag and how long the backlog takes to drain.
- [ ] Expire a hot cache key. Check whether concurrent misses cause a cache stampede.

> [!tip] Record the signal
> Save the metric that changed first and the knob you turned. Link the [[checkout|checkout simulator]] or your own map so you can repeat the experiment.
