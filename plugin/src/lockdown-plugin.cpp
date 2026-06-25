// Appliance UI/hotkey lockdown plugin.
//
// Disables and hides the Record/Replay Buffer/Virtual Camera/Settings
// widgets from the OBS main window, clears every registered hotkey's key
// bindings (including Start/Stop Streaming - this appliance only needs
// streaming controllable via the UI button and obs-websocket, not a
// physical key combo), and reacts to recording/replay-buffer start as a
// fallback kill-switch. This does NOT replace the other lockdown layers
// (obs-websocket auth, unwritable recording output path) - obs-websocket
// and any other in-process caller still reach
// obs_frontend_recording_start()/etc directly, bypassing the UI and hotkeys
// entirely.
//
// We deliberately use hide()/setEnabled(false), NOT deleteLater(): OBSBasic
// (OBS's main window class) keeps raw pointers to these exact widgets as
// member variables and dereferences them later from its own code - e.g.
// refreshing button state after a profile switch. deleteLater() destroys
// the QObject once the event loop turns over, so the next time OBS's own
// code touches that now-dangling pointer it segfaults with no graceful
// error logged. Observed in testing: switching profiles reliably crashed
// the whole obs process (and therefore the container) until this was
// changed from delete to hide+disable.
//
// IMPORTANT: the objectName()s below are best-effort guesses based on
// common OBS Qt widget naming conventions, NOT verified against the actual
// OBS 32.1.2 window-basic-main.ui/.cpp source. Before relying on this in
// production, inspect a running instance's widget tree (e.g. dump
// QObject::findChildren<QWidget*>() names at FINISHED_LOADING into the log)
// and correct this list.

#include <obs.h>
#include <obs-module.h>
#include <obs-frontend-api.h>

#include <QMainWindow>
#include <QAction>
#include <QPushButton>
#include <QMenu>

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("appliance-lockdown", "en-US")

namespace {

const char *const kActionNames[] = {
	"actionStartRecording",   "actionStopRecording",
	"actionStartReplayBuffer", "actionStopReplayBuffer",
	"actionStartVirtualCam",  "actionStopVirtualCam",
	"action_Settings",        "actionSettings",
	nullptr,
};

const char *const kButtonNames[] = {
	"recordButton", "replayBufferButton", "vcamButton",
	"settingsButton",
	nullptr,
};

void RemoveByObjectName(QMainWindow *win, const char *const *names)
{
	for (int i = 0; names[i]; ++i) {
		if (QAction *action = win->findChild<QAction *>(names[i])) {
			action->setEnabled(false);
			action->setVisible(false);
		}
		if (QPushButton *btn = win->findChild<QPushButton *>(names[i])) {
			btn->setEnabled(false);
			btn->setVisible(false);
		}
	}
}

// Hides every entry in the Tools menu. The appliance has no use for any of
// OBS's bundled Tools (Auto-Configuration Wizard, Output Timer, Auto Replay
// Buffer Timer, etc.) - if a specific tool ever needs to stay reachable,
// match on action->text() here instead of hiding all of them. setVisible
// rather than deleteLater for the same dangling-pointer reason as above.
void StripToolsMenu(QMainWindow *win)
{
	QMenu *toolsMenu = win->findChild<QMenu *>("menuTools");
	if (!toolsMenu)
		return;
	for (QAction *action : toolsMenu->actions()) {
		action->setEnabled(false);
		action->setVisible(false);
	}
}

// obs_enum_hotkeys() walks every hotkey registered in the process, not just
// ones this plugin registered itself, and obs_hotkey_load(id, <empty array>)
// clears a hotkey's key bindings without unregistering the action. We wipe
// every hotkey's bindings unconditionally - including Start/Stop Streaming -
// rather than name-matching for Record/Replay/VirtualCam specifically: this
// appliance only needs streaming controllable via the visible UI button and
// obs-websocket, not a physical keyboard shortcut, and not having to guess
// at OBS's internal hotkey name strings removes a whole class of "did we
// actually match the real name" risk.
bool HotkeyEnumCallback(void *, obs_hotkey_id id, obs_hotkey_t *)
{
	obs_data_array_t *empty = obs_data_array_create();
	obs_hotkey_load(id, empty);
	obs_data_array_release(empty);
	return true; // keep enumerating
}

void DisableAllHotkeys()
{
	obs_enum_hotkeys(HotkeyEnumCallback, nullptr);
}

void OnFrontendEvent(enum obs_frontend_event event, void *)
{
	switch (event) {
	case OBS_FRONTEND_EVENT_FINISHED_LOADING: {
		auto *win = (QMainWindow *)obs_frontend_get_main_window();
		if (!win)
			break;
		RemoveByObjectName(win, kActionNames);
		RemoveByObjectName(win, kButtonNames);
		StripToolsMenu(win);
		DisableAllHotkeys();
		break;
	}
	case OBS_FRONTEND_EVENT_RECORDING_STARTING:
		// libobs exposes no veto hook for *_STARTING - this only reacts
		// after the fact. Real prevention is the UI/hotkey removal above
		// plus the unwritable RecFilePath/FilePath baked into basic.ini
		// (see golden-config/), not this callback.
		obs_frontend_recording_stop();
		break;
	case OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTING:
		obs_frontend_replay_buffer_stop();
		break;
	default:
		break;
	}
}

} // namespace

bool obs_module_load(void)
{
	obs_frontend_add_event_callback(OnFrontendEvent, nullptr);
	return true;
}

void obs_module_unload(void) {}
