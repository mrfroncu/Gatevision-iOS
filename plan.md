# Web Panel Update Plan

## Backend (GateVisionApp.swift)
1. Add `plateCount()` and `logCount()` to Database class
2. Extend GET/POST `/api/settings` with: camera_resolution, camera_source, pi_address, mai_rtsp_url, detection_mode + available_* arrays
3. Add `camera_source` to `/api/status`
4. Add 3 new endpoints: GET `/api/debug`, POST `/api/ml_log/clear`, POST `/api/ml_log/toggle`

## Frontend (dashboard.html)
5. Add 5th "Debug" tab with: app info, OCR diagnostics, camera info, DB stats, ML log viewer
6. Extend Settings tab with: detection mode picker, camera source picker (+ Pi/70mai fields), camera resolution picker
7. Add JS functions for new controls + auto-refresh on Debug tab
