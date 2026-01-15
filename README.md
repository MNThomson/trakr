# trakr

macOS menu bar app for tracking active work time throughout the day.

Tracks keyboard, mouse, and power assertions (video calls, etc.). Bars fill up as you progress toward your daily goal. Notifies when daily goal is reached.

<div align="center">

![Menu Bar](assets/menu.svg)


**☀** Start time · **🏁** Finish time · **☕** Break time

</div>

## Settings

**Idle Threshold** — Seconds of inactivity before pausing (default: 120s)  
**Daily Hours Goal** — Target work hours per day (default: 8h)

**Wrap-Up Reminder** — Alert before reaching daily goal  
**Eye Break (20-20-20)** — Look 20ft away for 20s every N minutes  
**Stretch Break (Hourly)** — Stretch reminder at :55 each hour  
**Stand Up for Zoom** — Reminder to stand when joining a Zoom call  
**Stretch After Zoom** — Stretch reminder after Zoom calls end  
**Sunset Alert** — Reminder before sunset
**Set Location** — Coordinates for sunset calculation

**Slack Presence** — Show coworker photos in menu bar when they're online
- Require App Open — Only show presence when Slack is running
- Show Meeting Status — Display meeting indicators on profile photos

## Build & Run

```
./run.sh
```
