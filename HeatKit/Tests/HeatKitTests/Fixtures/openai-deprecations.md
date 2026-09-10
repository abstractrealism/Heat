<!--
Excerpts copied verbatim from OpenAI's deprecations page on 2026-09-10:
https://developers.openai.com/api/docs/deprecations.md

Trimmed to the shapes the parser has to cope with rather than kept whole:

  - a future-dated table, which must be ignored
  - a past-dated table naming bare aliases (gpt-5.1-chat-latest)
  - a cell holding two names separated by an escaped pipe
  - a cell holding exactly one name, which is the case a parity bug once
    skipped entirely
  - models listed with a past shutdown in one table and a future one in
    another (babbage-002, davinci-002), where the future date is operative
  - a four-column table, so the model column isn't found by counting from
    the right
  - endpoint paths sharing the tables with models
  - three date formats: 2026-09-28, Feb 26, 2027, and July 23, 2026
-->

## Upcoming deprecations

Upcoming deprecations are listed below, with the most recent announcements at the top.

### 2026-08-26: Transcription models

On August 26, 2026, we notified developers using `whisper-1`, `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`, and `gpt-4o-transcribe-diarize` of their deprecation and removal from the API on February 26, 2027.

For information about the recommended replacements, see the [transcription guide](https://developers.openai.com/api/docs/guides/transcription).

| Shutdown date | Model / system              | Recommended replacement                   |
| ------------- | --------------------------- | ----------------------------------------- |
| Feb 26, 2027  | `whisper-1`                 | `gpt-live-transcribe` or `gpt-transcribe` |
| Feb 26, 2027  | `gpt-4o-transcribe`         | `gpt-live-transcribe` or `gpt-transcribe` |
| Feb 26, 2027  | `gpt-4o-mini-transcribe`    | `gpt-live-transcribe` or `gpt-transcribe` |
| Feb 26, 2027  | `gpt-4o-transcribe-diarize` | `gpt-live-transcribe` or `gpt-transcribe` |


### 2025-09-26: Legacy GPT model snapshots

To improve reliability and make it easier for developers to choose the right models, we are deprecating a set of older OpenAI models with declining usage over the next six to twelve months. Access to these models will be shut down on the dates below.

| Shutdown date | Model / system           | Recommended replacement |
| ------------- | ------------------------ | ----------------------- |
| 2026-09-28    | `gpt-3.5-turbo-instruct` | `gpt-5.6-terra`         |
| 2026-09-28    | `babbage-002`            | `gpt-5.6-terra`         |
| 2026-09-28    | `davinci-002`            | `gpt-5.6-terra`         |
| 2026-09-28    | `gpt-3.5-turbo-1106`     | `gpt-5.6-terra`         |

## Past deprecations

Past deprecations are listed below, with the most recent announcements at the top.

### 2026-05-08: gpt-5.2-chat-latest and gpt-5.3-chat-latest model snapshots

On May 8th, 2026, we notified developers using `gpt-5.2-chat-latest` and `gpt-5.3-chat-latest` model snapshots of their deprecation and removal from the API.

| Shutdown date | Model / system        | Recommended replacement |
| ------------- | --------------------- | ----------------------- |
| Aug 10, 2026  | `gpt-5.2-chat-latest` | `gpt-5.6-sol`           |
| Aug 10, 2026  | `gpt-5.3-chat-latest` | `gpt-5.6-sol`           |

### 2026-04-22: Legacy GPT model snapshots (July 2026 shutdown)

On April 22, 2026, we announced the deprecation of the following older OpenAI models. Access to these models was shut down on July 23, 2026.

| Shutdown date | Model snapshot                                                | Substitute model        |
| ------------- | ------------------------------------------------------------- | ----------------------- |
| July 23, 2026 | `computer-use-preview-2025-03-11` \| `computer-use-preview`   | `gpt-5.6-terra`         |
| July 23, 2026 | `gpt-4o-mini-search-preview-2025-03-11`                       | `gpt-5.6-terra`         |
| July 23, 2026 | `gpt-4o-search-preview-2025-03-11`                            | `gpt-5.6-terra`         |
| July 23, 2026 | `gpt-5-chat-latest`                                           | `gpt-5.6-sol`           |
| July 23, 2026 | `gpt-5-codex`                                                 | `gpt-5.6-sol`           |
| July 23, 2026 | `gpt-5.1-chat-latest`                                         | `gpt-5.6-sol`           |
| July 23, 2026 | `gpt-5.1-codex`                                               | `gpt-5.6-sol`           |
| July 23, 2026 | `gpt-5.1-codex-max`                                           | `gpt-5.6-sol`           |
| July 23, 2026 | `gpt-5.1-codex-mini`                                          | `gpt-5.6-terra`         |
| July 23, 2026 | `gpt-audio-mini-2025-10-06`                                   | `gpt-audio-1.5`         |
| July 23, 2026 | `gpt-realtime-mini-2025-10-06`                                | `gpt-realtime-2.1-mini` |
| July 23, 2026 | `o3-deep-research-2025-06-26` \| `o3-deep-research`           | `gpt-5.6-sol`           |
| July 23, 2026 | `o4-mini-deep-research-2025-06-26` \| `o4-mini-deep-research` | `gpt-5.6-sol`           |
| July 23, 2026 | `gpt-5.2-codex`                                               | `gpt-5.6-sol`           |

### 2025-11-18: chatgpt-4o-latest snapshot

On November 18th, 2025, we notified developers using `chatgpt-4o-latest` model snapshot of its deprecation and removal from the API on February 17, 2026.

| Shutdown date | Model / system      | Recommended replacement |
| ------------- | ------------------- | ----------------------- |
| 2026-02-17    | `chatgpt-4o-latest` | `gpt-5.1-chat-latest`   |

### 2024-06-06: GPT-4-32K and Vision Preview models

On June 6th, 2024, we notified developers using `gpt-4-32k` and `gpt-4-vision-preview` of their upcoming deprecations in one year and six months respectively. As of June 17, 2024, only existing users of these models will be able to continue using them.

| Shutdown date | Deprecated model            | Deprecated model price                             | Recommended replacement |
| ------------- | --------------------------- | -------------------------------------------------- | ----------------------- |
| 2025-06-06    | `gpt-4-32k`                 | $60.00 / 1M input tokens + $120 / 1M output tokens | `gpt-4o`                |
| 2025-06-06    | `gpt-4-32k-0613`            | $60.00 / 1M input tokens + $120 / 1M output tokens | `gpt-4o`                |
| 2025-06-06    | `gpt-4-32k-0314`            | $60.00 / 1M input tokens + $120 / 1M output tokens | `gpt-4o`                |
| 2024-12-06    | `gpt-4-vision-preview`      | $10.00 / 1M input tokens + $30 / 1M output tokens  | `gpt-4o`                |
| 2024-12-06    | `gpt-4-1106-vision-preview` | $10.00 / 1M input tokens + $30 / 1M output tokens  | `gpt-4o`                |

| Shutdown date | System                | Recommended replacement                                                                               |
| ------------- | --------------------- | ----------------------------------------------------------------------------------------------------- |
| 2022-12-03    | `/v1/engines`         | [/v1/models](https://platform.openai.com/docs/api-reference/models/list)                              |
| 2022-12-03    | `/v1/search`          | [View transition guide](https://help.openai.com/en/articles/6272952-search-transition-guide)          |
| 2022-12-03    | `/v1/classifications` | [View transition guide](https://help.openai.com/en/articles/6272941-classifications-transition-guide) |
| 2022-12-03    | `/v1/answers`         | [View transition guide](https://help.openai.com/en/articles/6233728-answers-transition-guide)         |
