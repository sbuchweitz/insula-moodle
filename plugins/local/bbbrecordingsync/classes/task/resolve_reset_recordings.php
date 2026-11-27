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

namespace local_bbbrecordingsync\task;

use local_bbbrecordingsync\resolver;

/**
 * Moves BigBlueButton recordings out of RESET status once the server confirms it does not have them.
 *
 * @package    local_bbbrecordingsync
 * @copyright  2026 The insula-moodle authors
 * @license    https://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */
class resolve_reset_recordings extends \core\task\scheduled_task {
    /**
     * Name shown in the scheduled task list.
     *
     * @return string
     */
    public function get_name(): string {
        return get_string('task_resolve_reset_recordings', 'local_bbbrecordingsync');
    }

    /**
     * Run the resolver and log what it did.
     */
    public function execute(): void {
        $counts = resolver::resolve_reset_recordings();
        mtrace(sprintf(
            'Recordings in RESET status: %d found on the server (now processed), '
                . '%d back to awaiting, %d dismissed, %d not checked because the server did not answer.',
            $counts['found'],
            $counts['awaiting'],
            $counts['dismissed'],
            $counts['unreachable']
        ));
    }
}
