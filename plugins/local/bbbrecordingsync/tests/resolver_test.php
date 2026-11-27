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

use advanced_testcase;
use mod_bigbluebuttonbn\instance;
use mod_bigbluebuttonbn\recording;
use mod_bigbluebuttonbn\task\check_pending_recordings;
use mod_bigbluebuttonbn\test\testcase_helper_trait;
use PHPUnit\Framework\Attributes\CoversClass;

/**
 * Tests for resolving recordings stuck in RESET status.
 *
 * Needs the BigBlueButton mock server (TEST_MOD_BIGBLUEBUTTONBN_MOCK_SERVER), like mod_bigbluebuttonbn's own tests.
 *
 * @package    local_bbbrecordingsync
 * @copyright  2026 The insula-moodle authors
 * @license    https://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later
 */
#[CoversClass(resolver::class)]
#[CoversClass(task\resolve_reset_recordings::class)]
final class resolver_test extends advanced_testcase {
    use testcase_helper_trait;

    /** @var instance BigBlueButton activity the recordings belong to */
    private instance $instance;

    public function setUp(): void {
        parent::setUp();
        $this->initialise_mock_server();
        $this->resetAfterTest();
        $generator = $this->getDataGenerator()->get_plugin_generator('mod_bigbluebuttonbn');
        $course = $this->getDataGenerator()->create_course();
        $activity = $generator->create_instance(['course' => $course->id, 'type' => instance::TYPE_ALL]);
        $this->instance = instance::get_from_instanceid($activity->id);
        $generator->create_meeting([
            'instanceid' => $this->instance->get_instance_id(),
            'groupid' => $this->instance->get_group_id(),
        ]);
    }

    /**
     * Recording that exists on the BigBlueButton server, in RESET status as after a server URL change.
     */
    private function server_recording(): recording {
        $generator = $this->getDataGenerator()->get_plugin_generator('mod_bigbluebuttonbn');
        $data = $generator->create_recording(['bigbluebuttonbnid' => $this->instance->get_instance_id()]);
        return $this->with_status(new recording($data->id), recording::RECORDING_STATUS_RESET);
    }

    /**
     * Recording row the server has never heard of (meeting without recording marks, or deleted there).
     *
     * @param int $daysold age of the Moodle row
     * @param int $status status to leave it in
     */
    private function ghost_recording(int $daysold, int $status = recording::RECORDING_STATUS_RESET): recording {
        global $DB;
        $generator = $this->getDataGenerator()->get_plugin_generator('mod_bigbluebuttonbn');
        // The generator only skips the mock server for dismissed recordings.
        $data = $generator->create_recording([
            'bigbluebuttonbnid' => $this->instance->get_instance_id(),
            'status' => recording::RECORDING_STATUS_DISMISSED,
        ]);
        $DB->set_field('bigbluebuttonbn_recordings', 'timecreated', time() - $daysold * DAYSECS, ['id' => $data->id]);
        return $this->with_status(new recording($data->id), $status);
    }

    /**
     * Save a recording with the given status.
     *
     * @param recording $recording
     * @param int $status
     * @return recording
     */
    private function with_status(recording $recording, int $status): recording {
        $recording->set('status', $status);
        $recording->save();
        return $recording;
    }

    /**
     * Status of a recording as stored in the database.
     *
     * @param recording $recording
     * @return int
     */
    private function status_of(recording $recording): int {
        return (int) (new recording($recording->get('id')))->get('status');
    }

    public function test_confirmed_missing_recordings_leave_reset(): void {
        $old = $this->ghost_recording(45);
        $young = $this->ghost_recording(3);

        $counts = resolver::resolve_reset_recordings();

        $this->assertSame(recording::RECORDING_STATUS_DISMISSED, $this->status_of($old));
        $this->assertSame(recording::RECORDING_STATUS_AWAITING, $this->status_of($young));
        $this->assertSame(['found' => 0, 'awaiting' => 1, 'dismissed' => 1, 'unreachable' => 0], $counts);
    }

    public function test_recordings_on_the_server_are_marked_processed(): void {
        $onserver = $this->server_recording();
        $ghost = $this->ghost_recording(45);

        $counts = resolver::resolve_reset_recordings();

        $this->assertSame(recording::RECORDING_STATUS_PROCESSED, $this->status_of($onserver));
        $this->assertSame(recording::RECORDING_STATUS_DISMISSED, $this->status_of($ghost));
        $this->assertSame(['found' => 1, 'awaiting' => 0, 'dismissed' => 1, 'unreachable' => 0], $counts);

        // Core's own task agrees and finds nothing left to change.
        ob_start();
        (new check_pending_recordings())->execute();
        ob_end_clean();
        $this->assertSame(recording::RECORDING_STATUS_PROCESSED, $this->status_of($onserver));
    }

    public function test_imported_copies_sharing_a_recording_id_leave_reset_too(): void {
        global $DB;
        $generator = $this->getDataGenerator()->get_plugin_generator('mod_bigbluebuttonbn');
        $other = $generator->create_instance(['course' => $this->instance->get_course_id()]);
        $otherinstance = instance::get_from_instanceid($other->id);
        $onserver = $this->server_recording();
        $ghost = $this->ghost_recording(45);
        // Copies made with "Import recording links" share the original's recordingid.
        $copies = [];
        foreach ([$onserver, $ghost] as $original) {
            $copy = $original->create_imported_recording($otherinstance);
            $DB->set_field('bigbluebuttonbn_recordings', 'timecreated', $original->get('timecreated'), ['id' => $copy->get('id')]);
            $copies[] = $this->with_status(new recording($copy->get('id')), recording::RECORDING_STATUS_RESET);
        }

        $counts = resolver::resolve_reset_recordings();

        $this->assertSame(recording::RECORDING_STATUS_PROCESSED, $this->status_of($copies[0]));
        $this->assertSame(recording::RECORDING_STATUS_DISMISSED, $this->status_of($copies[1]));
        $this->assertSame(0, recording::count_records(['status' => recording::RECORDING_STATUS_RESET]));
        $this->assertSame(['found' => 2, 'awaiting' => 0, 'dismissed' => 2, 'unreachable' => 0], $counts);
    }

    public function test_dismissal_updates_timemodified_so_check_dismissed_recordings_rechecks_it(): void {
        global $DB;
        $ghost = $this->ghost_recording(45);
        $DB->set_field('bigbluebuttonbn_recordings', 'timemodified', time() - 60 * DAYSECS, ['id' => $ghost->get('id')]);

        resolver::resolve_reset_recordings();

        $timemodified = (int) $DB->get_field('bigbluebuttonbn_recordings', 'timemodified', ['id' => $ghost->get('id')]);
        $this->assertGreaterThan(time() - recording::RECORDING_TIME_LIMIT_DAYS * DAYSECS, $timemodified);
    }

    public function test_nothing_changes_while_the_server_rejects_requests(): void {
        $onserver = $this->server_recording();
        $old = $this->ghost_recording(45);
        $young = $this->ghost_recording(3);
        // Secret rotated on BigBlueButton but not yet in Moodle: every call fails with checksumError.
        set_config('bigbluebuttonbn_shared_secret', 'not-the-secret-the-server-uses');

        $counts = resolver::resolve_reset_recordings();

        foreach ([$onserver, $old, $young] as $recording) {
            $this->assertSame(recording::RECORDING_STATUS_RESET, $this->status_of($recording));
        }
        $this->assertSame(['found' => 0, 'awaiting' => 0, 'dismissed' => 0, 'unreachable' => 3], $counts);
    }

    public function test_other_statuses_are_not_touched(): void {
        $awaiting = $this->ghost_recording(45, recording::RECORDING_STATUS_AWAITING);
        $processed = $this->ghost_recording(45, recording::RECORDING_STATUS_PROCESSED);
        $dismissed = $this->ghost_recording(10, recording::RECORDING_STATUS_DISMISSED);

        $counts = resolver::resolve_reset_recordings();

        $this->assertSame(recording::RECORDING_STATUS_AWAITING, $this->status_of($awaiting));
        $this->assertSame(recording::RECORDING_STATUS_PROCESSED, $this->status_of($processed));
        $this->assertSame(recording::RECORDING_STATUS_DISMISSED, $this->status_of($dismissed));
        $this->assertSame(['found' => 0, 'awaiting' => 0, 'dismissed' => 0, 'unreachable' => 0], $counts);
    }

    public function test_a_second_run_has_nothing_left_to_do(): void {
        $this->ghost_recording(45);
        resolver::resolve_reset_recordings();

        $this->assertSame(
            ['found' => 0, 'awaiting' => 0, 'dismissed' => 0, 'unreachable' => 0],
            resolver::resolve_reset_recordings()
        );
    }

    public function test_scheduled_task_reports_what_it_did(): void {
        $this->ghost_recording(45);
        $this->ghost_recording(3);

        $this->expectOutputRegex('/0 found on the server.*1 back to awaiting.*1 dismissed.*0 not checked/');
        (new task\resolve_reset_recordings())->execute();
    }
}
