---
name: Hardware report
about: Tell us whether this works on hardware different from the machine it was built on
title: "[hardware] "
labels: hardware-report
---

<!--
This project was developed against one specific machine, so reports from
different configurations are the most useful thing you can send.

A report that says "it doesn't work" cannot be acted on. A report with the
USB IDs and the output of one probe script usually can.
-->

## What happened

<!-- What did you expect, and what did the app do instead? -->

## Your hardware

| | |
|---|---|
| Motherboard | |
| CPU | |
| GPU | |
| Lian Li devices | <!-- e.g. UNI FAN TL 120 x3, Galahad II 360 --> |
| RAM | <!-- brand, DDR4 or DDR5, how many modules --> |
| Windows version | <!-- winver --> |

## Devices the app can see

Run this and paste the whole output — it only reads, it writes nothing:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\probe-tl.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools\probe-ga2.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools\probe-lcd.ps1
```

```
paste here
```

## If the problem is RAM RGB

RAM RGB needs administrator and PawnIO. Paste the output of:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\probe-smbus.ps1
```

```
paste here
```

## Status panel

<!-- Copy the text from the Status box at the bottom of the window, or attach
     a screenshot of the whole window. -->

## Anything else

<!-- Vendor software still installed? Did it work before? Anything unusual? -->
