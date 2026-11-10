#pragma once

class QString;

// Keeps every OBS file dialog (Add Source file pickers, Browse buttons, ...)
// inside `root`: it opens there, the sidebar only lists it, the path
// dropdown and the Back, Forward, Up and New Folder buttons are hidden,
// leaving the folder jumps back, and the file name box refuses paths. This
// is a usability layer: the bwrap jail in entrypoint.sh is what limits what
// OBS can read. Does nothing (and logs a warning) when `root` doesn't exist,
// so a missing mount never breaks the dialogs.
void InstallFileDialogGuard(const QString &root);
