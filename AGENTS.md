# Agent Instructions — HideGCDSweep

## Overview

HideGCDSweep is a World of Warcraft addon that hides the swipe/sweep animation on Blizzard's Cooldown Manager icons (Essential, Utility, Buff trackers).

## WoW API Reference

 - `wow-ui-source/Interface/Blizzard_APIDocumentationGenerated/` contains **all WoW API documentation** (functions, enums, constants, events) for the current game version. Search by keyword to find the relevant file.
 
 - `wow-ui-source/Interface/AddOns/` contains **Blizzard's own UI source code** that ships with the game. Look here to see how APIs are actually used in practice.

## WoW 12.0 Secrets System

WoW 12.0 introduces a secrets system that restricts many APIs during combat. Always inspect the API documentation in `wow-ui-source/Interface/Blizzard_APIDocumentationGenerated/` for any secrets-related restrictions before using an API. Always assume we are in combat if not stated otherwise.