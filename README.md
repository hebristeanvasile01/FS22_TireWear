# FS22 Tire Wear

A Farming Simulator 22 mod. Tires wear out with the distance you drive: the more worn they are, the less grip your vehicle has, and from 60% wear the tread visibly wears down.

## Features

- Wear depends on the distance driven (about 300 km for a full set)
- Grip loss grows with wear, up to -50% at 100% wear
- Visible tread wear (custom shader) from 60% wear; new tires keep the original look
- Warnings at 80% and 95% wear
- Wear shown in the vehicle info box and saved with the savegame
- Replace tires in the workshop with the **Replace tires** button next to Repair (click or **R**), costs 3% of the vehicle price
- Works on all motorized vehicles with wheels
- Multiplayer supported
- Languages: English, German, French

## Console commands

| Command | Description |
|---|---|
| `tireWearSet <0-100>` | Sets the tire wear of the vehicle you are driving |
| `tireWearRate <km>` | Sets how many km until tires are fully worn (testing) |

## Settings

Wear rate, grip loss, replacement price and the start of the visual wear are at the top of `scripts/TireWear.lua`.

## Installation

Download the mod from ModHub / KingMods, or zip the repository contents so that `modDesc.xml` is at the root of the archive, and name it `FS22_TireWear.zip`. Put it in `Documents/My Games/FarmingSimulator2022/mods`.

## Credits

Author: FS Modding. The visual wear idea is inspired by "Use Up Your Tyres" (FS25) by 50keda.
