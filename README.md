# loopiii
A multitrack MIDI looper for Monome Grid using iii

Current Version 1.0.0

[![loopiii 1.0 demo](img/loopiii_1.0_thumbnail.jpg)](https://www.youtube.com/watch?v=)


## Overview
Loopiii is a 6-track MIDI looper with performance controls. The intuitive UI makes navigation and use as easy as possible without needing to memorize obscure button presses.

Loopiii allows for all tracks to be asynchronously or synchronously recorded to any length or a specific bar length. Loops can be overdubbed, quantized, slowed, sped up, time stretched, or played as a one-shot. Tracks can be synced to one another to share lengths and other properties.

Loopiii needs the input of another MIDI device to record notes and events. Combine loopiii with foot switches to control various functions without needing to interact with the grid directly.
![Overview](img/loopiii_Overview.png)

## MIDI - Presets & CCs  
**[FF] MIDI Presets**  
Presets are only for saving MIDI configurations across all tracks. Presets can be saved by holding a slot for 2 seconds and loaded by pressing a slot.

Presets are numbered 1-8. In diii you will see files that look like this:  
`pset_loopiii_1.lua`

Global preset:  
`pset_loopiii_100.lua`
serves as a global state memory. It recalls the last loaded preset to run when the script starts. It is updated when pressing any preset button.

**MIDI CCs**
Loopiii has many functions that can be controlled from a momentary foot switch or any device that can send continuous control signals. This is the list of available controls:
| CC Number | Function |
| :--- | :--- |
| CC 102 | Global Play/Stop |
| CC 103 | Global Reset |
| CC 104 | Select Previous Track |
| CC 105 | Select Next Track |
| CC 106 | Record Current Track |
| CC 107 | Play/Stop Current Track |
| CC 108 | Reset Current Track |
| CC 109 | Mute Current Track |
| CC 110 | 1/2x Speed Current Track |
| CC 111 | 1x Speed Current Track |
| CC 112 | 2x Speed Current Track |

![Perform Presets](img/loopiii_MIDI-Presets.png)
