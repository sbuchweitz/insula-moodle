<?php
// This file is part of Moodle - https://moodle.org/
//
// Moodle is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Moodle is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Moodle.  If not, see <https://www.gnu.org/licenses/>.

namespace local_bbbrecordingsync;

use mod_bigbluebuttonbn\local\proxy\recording_proxy;
use mod_bigbluebuttonbn\recording;

/**
 * Moves recordings out of RESET status once the BigBlueButton server confirms it does not have them.
 *
 * Changing the server URL sets every recording to RESET, and check_pending_recordings queries RESET recordings
 * on every run with no time limit, so those the server never had (meetings without recording marks) or has
 * deleted, and imported copies of found ones, are queried forever. This applies the rule mod_bigbluebuttonbn
 * already uses when listing recordings:
 * only a recording the server answered for, but without it, is treated as missing; when a request fails the
 * recording is left alone (see MDL-80225).
 *
 * @package    local_bbbrecordingsync
 * @copyright  2026 The insula-moodle authors
 * @license    https://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */
class resolver {
    /**
     * Resolve all recordings in RESET status.
     *
     * Recordings the server has become processed, like check_pending_recordings does, but for every record with
     * that recording id (imported copies share it; core only updates the first). Confirmed missing ones become
     * dismissed when older than the module's time limit (check_dismissed_recordings still re-checks them for that
     * long), otherwise awaiting, so they age out like any pending recording.
     *
     * @return array<string, int> counts: found, awaiting, dismissed, unreachable
     */
    public static function resolve_reset_recordings(): array {
        $counts = ['found' => 0, 'awaiting' => 0, 'dismissed' => 0, 'unreachable' => 0];
        $recordings = recording::get_records(['status' => recording::RECORDING_STATUS_RESET]);
        if (!$recordings) {
            return $counts;
        }

        $recordingids = array_map(fn(recording $recording): string => $recording->get('recordingid'), $recordings);
        $found = recording_proxy::fetch_recordings($recordingids);
        $missing = array_values(array_diff($recordingids, array_keys($found)));
        $unanswered = array_flip(recording_proxy::fetch_missing_recordings($missing));
        $cutoff = time() - recording::RECORDING_TIME_LIMIT_DAYS * DAYSECS;

        foreach ($recordings as $recording) {
            $recordingid = $recording->get('recordingid');
            if (array_key_exists($recordingid, $found)) {
                [$status, $outcome] = [recording::RECORDING_STATUS_PROCESSED, 'found'];
            } else if (array_key_exists($recordingid, $unanswered)) {
                $counts['unreachable']++;
                continue;
            } else if ($recording->get('timecreated') < $cutoff) {
                [$status, $outcome] = [recording::RECORDING_STATUS_DISMISSED, 'dismissed'];
            } else {
                [$status, $outcome] = [recording::RECORDING_STATUS_AWAITING, 'awaiting'];
            }
            if (self::set_status_if_still_reset((int) $recording->get('id'), $status)) {
                $counts[$outcome]++;
            }
        }
        return $counts;
    }

    /**
     * Change the status of a recording that is still in RESET.
     *
     * The server requests above take minutes for a large backlog, and saving writes every column, so the record is
     * read again: a change made in the meantime (published by check_pending_recordings, headless flag) is kept.
     *
     * @param int $id recording record id
     * @param int $status new status
     * @return bool whether the status was changed
     */
    private static function set_status_if_still_reset(int $id, int $status): bool {
        $current = recording::get_record(['id' => $id]);
        if (!$current || (int) $current->get('status') !== recording::RECORDING_STATUS_RESET) {
            return false;
        }
        $current->set('status', $status); // Saved by recording::set_status().
        return true;
    }
}
