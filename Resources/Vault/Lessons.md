# Lessons

- [[checkout]] Trace a checkout through pricing, a database commit, and email confirmation.
- [[rabbitmq-prefetch]] Compare broker and worker queues, then crash a consumer under each acknowledgement mode.
- [[kafka-consumer-groups]] Watch two groups read the same topic and see how lag can turn into retention loss.
- [[retries-timeouts]] Measure how retries amplify load and how a timeout or breaker changes the outcome.
- [[cache-stampede]] Flush a warm cache and use a concurrency limit to keep excess reads away from Postgres.
- [[thread-pool-exhaustion]] Compare eight blocking threads with asynchronous I/O and a bounded timeout.
- [[queueing-latency]] Raise utilization toward 95% and watch queueing change request p99.
- [[transactional-outbox]] Take Kafka down and compare which committed events can reach consumers after recovery.
- [[load-balancing]] Route traffic away from a slow replica, then replace lost capacity.
- [[llm-gateway]] Compare cached replies, queue admission, and a smaller model during a primary timeout.

## Try retries and timeouts

Watch upstream traffic after the first timeouts, then compare what happens when the API starts retrying.

```strata
sim: retries-timeouts
scenario: retry-amplification
height: 420
```
