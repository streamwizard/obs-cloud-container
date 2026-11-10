#include "file-dialog-guard.hpp"

#include <obs-module.h>

#include <QApplication>
#include <QDir>
#include <QEvent>
#include <QFileDialog>
#include <QFileInfo>
#include <QLineEdit>
#include <QTimer>
#include <QUrl>
#include <QValidator>
#include <QWidget>

#include <utility>

namespace {

const char kGuardedProperty[] = "applianceLockdownGuarded";

// QFileDialog's own widgets, by the objectNames its .ui file gives them.
const char *const kHiddenDialogWidgets[] = {
	"lookInLabel",     // "Look in:"
	"lookInCombo",     // path dropdown that lists every parent folder
	"backButton",      // folder history; the sidebar entry leads home
	"forwardButton",
	"toParentButton",
	"newFolderButton", // media is managed from the dashboard
	nullptr,
};

bool IsInside(const QString &root, const QString &path)
{
	const QString clean = QDir::cleanPath(path);
	return clean == root || clean.startsWith(root + QLatin1Char('/'));
}

// The file name box takes names only. A '/' would allow an absolute path or
// a ../ climb out of the folder, including inside a quoted multi-file list
// ("a.png" "/etc/hosts"). Typing ".." or "~" alone and pressing Enter only
// changes folder, which the directoryEntered snap below undoes.
class NameOnlyValidator : public QValidator {
public:
	using QValidator::QValidator;

	State validate(QString &input, int &) const override
	{
		return input.contains(QLatin1Char('/')) ? Invalid : Acceptable;
	}
};

class FileDialogGuard : public QObject {
public:
	FileDialogGuard(QString root, QObject *parent) : QObject(parent), root_(std::move(root)) {}

protected:
	bool eventFilter(QObject *obj, QEvent *event) override
	{
		if (event->type() == QEvent::Show) {
			if (auto *dialog = qobject_cast<QFileDialog *>(obj))
				Restrict(dialog);
		}
		return QObject::eventFilter(obj, event);
	}

private:
	void Restrict(QFileDialog *dialog)
	{
		// OBS opens a picker in the folder of the current file or the last
		// one used; anything outside the media folder starts at its root.
		if (!IsInside(root_, dialog->directory().absolutePath()))
			dialog->setDirectory(root_);

		if (dialog->property(kGuardedProperty).toBool())
			return;
		dialog->setProperty(kGuardedProperty, true);

		dialog->setSidebarUrls({QUrl::fromLocalFile(root_)});
		dialog->setHistory({});
		for (int i = 0; kHiddenDialogWidgets[i]; ++i) {
			if (auto *widget = dialog->findChild<QWidget *>(QLatin1String(kHiddenDialogWidgets[i])))
				widget->hide();
		}
		if (auto *edit = dialog->findChild<QLineEdit *>(QStringLiteral("fileNameEdit")))
			edit->setValidator(new NameOnlyValidator(edit));

		// The sidebar's media entry is the way back out of a subfolder.
		// Anything else that leaves the folder (typing ".." or "~" in the
		// file name box) lands back on it. Deferred so the dialog finishes
		// its own navigation first.
		const QString root = root_;
		QObject::connect(dialog, &QFileDialog::directoryEntered, dialog, [dialog, root](const QString &path) {
			if (!IsInside(root, path))
				QTimer::singleShot(0, dialog, [dialog, root] { dialog->setDirectory(root); });
		});
	}

	QString root_;
};

} // namespace

void InstallFileDialogGuard(const QString &root)
{
	static bool installed = false;
	if (installed)
		return;

	const QString canonical = QFileInfo(root).canonicalFilePath();
	if (canonical.isEmpty()) {
		blog(LOG_WARNING, "[appliance-lockdown] %s not found, file dialogs are not restricted",
		     qPrintable(root));
		return;
	}

	// Native (portal/GTK) dialogs aren't QFileDialog widgets, so the filter
	// couldn't reach them. The container has neither today; this keeps it so.
	QCoreApplication::setAttribute(Qt::AA_DontUseNativeDialogs);
	qApp->installEventFilter(new FileDialogGuard(canonical, qApp));
	installed = true;
	blog(LOG_INFO, "[appliance-lockdown] file dialogs kept inside %s", qPrintable(canonical));
}
