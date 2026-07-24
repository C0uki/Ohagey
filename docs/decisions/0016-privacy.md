# 0016: Privacy

## Decision
Ohagey performs no network communication except:
1. The one-time model/dictionary download at install time (decision 0008)
2. Optional, user-initiated re-download/retry from the settings app

All conversion (including Zenzai neural inference) happens locally on the user's
CPU/GPU (decision 0010). No keystrokes, conversion candidates, learning data, or
usage statistics are ever transmitted externally. There is no telemetry and no
crash reporting service.

## Why
- IMEs see every character a user types — trust here is not optional
- Matches azooKey's own stated privacy stance ("完全オフラインで動作し、入力内容は
  外部に送信されません")
- The architecture (decisions 0004–0007: local shared-memory-adjacent server process,
  named-pipe IPC, offline Zenzai inference) already makes offline-only operation the
  natural, low-effort outcome — adding telemetry would be the thing requiring extra
  work, not the other way around
- Particularly important for the anticipated school-PC deployment scenario

## What this means for future contributors
Any future feature that would add network calls beyond the model-download path
(e.g. crash reporting, usage analytics, cloud dictionary sync) requires revisiting
this decision explicitly — it is not a default to add opportunistically.
