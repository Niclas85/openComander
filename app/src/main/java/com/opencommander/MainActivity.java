package com.opencommander;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.content.res.Configuration;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.SystemClock;
import android.provider.Settings;
import android.text.InputType;
import android.view.DragEvent;
import android.view.Gravity;
import android.view.inputmethod.EditorInfo;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.webkit.MimeTypeMap;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.ProgressBar;
import android.widget.Switch;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.text.DateFormat;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;

public class MainActivity extends Activity {
    private static final int REQUEST_STORAGE = 100;
    private static final long DOUBLE_TAP_MS = 450L;
    private static final String PREF_DARK_MODE = "dark_mode";
    private static final String PREF_LANGUAGE = "language";

    private CommanderPane leftPane;
    private CommanderPane rightPane;
    private CommanderPane activeDragPane;
    private Switch darkModeSwitch;
    private Button undoButton;
    private Button zipButton;
    private Button deleteButton;
    private Button historyButton;
    private Button languageButton;
    private LinearLayout historyPanel;
    private TextView globalStatus;
    private ProgressBar progressBar;
    private TextView progressText;
    private final List<LastOperation> undoHistory = new ArrayList<>();
    private final Locale systemLocale = Locale.getDefault();
    private CommanderPane activePane;
    private boolean moveMode;
    private boolean historyExpanded;
    private boolean darkMode;
    private ThemeColors theme;
    private int baseTopPadding;
    private int baseBottomPadding;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        requestStorageAccessIfNeeded();

        SharedPreferences prefs = getPreferences(MODE_PRIVATE);
        applyLanguage(prefs.getString(PREF_LANGUAGE, ""));
        darkMode = prefs.getBoolean(PREF_DARK_MODE, false);
        theme = new ThemeColors(darkMode);
        prefs.edit().remove("left").remove("right").apply();

        File start = deviceRoot();
        leftPane = new CommanderPane("1", start, "#1E66C1");
        rightPane = new CommanderPane("2", start, "#1F8A5B");
        buildLayout();
        refreshEverything(getString(R.string.ready));
    }

    @Override
    public void onConfigurationChanged(Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        buildLayout();
        refreshEverything(getString(R.string.ready));
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (leftPane != null && rightPane != null) {
            refreshEverything(getString(R.string.ready));
        }
    }

    private void buildLayout() {
        theme = new ThemeColors(darkMode);
        boolean portrait = getResources().getConfiguration().orientation == Configuration.ORIENTATION_PORTRAIT;

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        baseTopPadding = portrait ? dp(10) : dp(4);
        baseBottomPadding = portrait ? dp(8) : dp(4);
        int sidePadding = portrait ? dp(10) : dp(6);
        root.setPadding(sidePadding, baseTopPadding, sidePadding, baseBottomPadding);
        root.setBackgroundColor(color(theme.appBackground));
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT_WATCH) {
            root.setOnApplyWindowInsetsListener((view, insets) -> {
                int top = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
                        ? insets.getInsets(WindowInsets.Type.systemBars()).top
                        : insets.getSystemWindowInsetTop();
                int bottom = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
                        ? insets.getInsets(WindowInsets.Type.systemBars()).bottom
                        : insets.getSystemWindowInsetBottom();
                view.setPadding(sidePadding, baseTopPadding + top, sidePadding, baseBottomPadding + bottom);
                return insets;
            });
        }

        LinearLayout.LayoutParams topBarParams = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
        topBarParams.setMargins(0, 0, 0, portrait ? dp(6) : dp(3));
        root.addView(createTopBar(), topBarParams);

        historyPanel = new LinearLayout(this);
        historyPanel.setOrientation(LinearLayout.VERTICAL);
        historyPanel.setPadding(dp(8), dp(6), dp(8), dp(6));
        historyPanel.setBackground(rounded(theme.panelBackground, theme.panelBorder, 1, 8));
        historyPanel.setVisibility(historyExpanded ? View.VISIBLE : View.GONE);
        LinearLayout.LayoutParams historyParams = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
        historyParams.setMargins(0, 0, 0, dp(8));
        root.addView(historyPanel, historyParams);
        rebuildHistoryPanel();

        LinearLayout commanders = new LinearLayout(this);
        commanders.setOrientation(portrait ? LinearLayout.VERTICAL : LinearLayout.HORIZONTAL);
        commanders.setBaselineAligned(false);
        commanders.addView(leftPane.createView(), paneParams(portrait, true));
        commanders.addView(rightPane.createView(), paneParams(portrait, false));
        root.addView(commanders, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0,
                1f));

        progressText = new TextView(this);
        progressText.setTextColor(color(theme.secondaryText));
        progressText.setTextSize(13);
        progressText.setTypeface(Typeface.DEFAULT_BOLD);
        progressText.setSingleLine(false);
        progressText.setPadding(dp(4), dp(8), dp(4), dp(3));
        root.addView(progressText, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));

        progressBar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        progressBar.setMax(1000);
        progressBar.setProgress(0);
        progressBar.setVisibility(View.GONE);
        root.addView(progressBar, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                dp(8)));

        globalStatus = new TextView(this);
        globalStatus.setTextColor(color(theme.secondaryText));
        globalStatus.setTextSize(12);
        globalStatus.setSingleLine(true);
        globalStatus.setPadding(dp(4), dp(6), dp(4), 0);
        root.addView(globalStatus, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));

        setContentView(root);
        updateUndoButton();
    }

    private LinearLayout.LayoutParams paneParams(boolean portrait, boolean first) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                portrait ? ViewGroup.LayoutParams.MATCH_PARENT : 0,
                portrait ? 0 : ViewGroup.LayoutParams.MATCH_PARENT,
                1f);
        if (first) {
            if (portrait) {
                params.setMargins(0, 0, 0, dp(8));
            } else {
                params.setMargins(0, 0, dp(8), 0);
            }
        }
        return params;
    }

    private View createTopBar() {
        boolean landscape = getResources().getConfiguration().orientation != Configuration.ORIENTATION_PORTRAIT;
        darkModeSwitch = null;
        LinearLayout topBar = new LinearLayout(this);
        topBar.setOrientation(landscape ? LinearLayout.HORIZONTAL : LinearLayout.VERTICAL);
        topBar.setGravity(Gravity.CENTER_VERTICAL);
        topBar.setPadding(
                landscape ? dp(8) : dp(12),
                landscape ? dp(4) : dp(10),
                landscape ? dp(8) : dp(12),
                landscape ? dp(4) : dp(10));
        topBar.setBackground(rounded(theme.headerBackground, theme.panelBorder, 1, 12));

        LinearLayout titleRow = new LinearLayout(this);
        titleRow.setOrientation(LinearLayout.HORIZONTAL);
        titleRow.setGravity(Gravity.CENTER_VERTICAL);

        TextView title = new TextView(this);
        title.setText(getString(R.string.app_name));
        title.setTextColor(color(theme.headerText));
        title.setTextSize(landscape ? 16 : 20);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        title.setSingleLine(true);
        titleRow.addView(title, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        Button legalButton = miniButton(getString(R.string.legal_short));
        makeLowPriorityButton(legalButton);
        legalButton.setOnClickListener(view -> showLegalDialog());
        if (!landscape) {
            addHeaderButton(titleRow, legalButton);
        }

        languageButton = miniButton(getString(R.string.language));
        makeLowPriorityButton(languageButton);
        languageButton.setOnClickListener(view -> showLanguageDialog());
        if (!landscape) {
            addHeaderButton(titleRow, languageButton);
        }

        LinearLayout.LayoutParams titleParams = new LinearLayout.LayoutParams(
                landscape ? 0 : ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                landscape ? 0.22f : 0f);
        if (landscape) {
            titleParams.setMargins(0, 0, dp(6), 0);
        }
        topBar.addView(titleRow, titleParams);

        LinearLayout controlsRow = new LinearLayout(this);
        controlsRow.setOrientation(LinearLayout.HORIZONTAL);
        controlsRow.setGravity(Gravity.CENTER_VERTICAL);
        controlsRow.setPadding(0, landscape ? 0 : dp(6), 0, 0);

        undoButton = miniButton(getString(R.string.undo));
        tintButton(undoButton, "#D8EAFF", "#4F96E8", "#073E7D", "#123A66", "#3B82F6", "#E6F2FF");
        if (landscape) {
            makeLandscapeButton(undoButton);
        }
        undoButton.setOnClickListener(view -> undoNewestOperation());
        addControlButton(controlsRow, undoButton, landscape);

        deleteButton = miniButton(getString(R.string.delete_button));
        tintButton(deleteButton, "#FFE4E0", "#E88778", "#7A2017", "#51231F", "#C24131", "#FFECE8");
        if (landscape) {
            makeLandscapeButton(deleteButton);
        } else {
            makeSecondaryPortraitButton(deleteButton);
        }
        deleteButton.setOnClickListener(view -> confirmDeleteSelection());
        addControlButton(controlsRow, deleteButton, landscape);

        if (landscape) {
            Button operationButton = miniButton(moveMode ? getString(R.string.move) : getString(R.string.copy));
            tintButton(operationButton, "#E9F8EF", "#91D5A7", "#1F6B3A", "#173F2A", "#2D8A50", "#DDFBE8");
            makeLandscapeButton(operationButton);
            operationButton.setOnClickListener(view -> {
                moveMode = !moveMode;
                operationButton.setText(moveMode ? getString(R.string.move) : getString(R.string.copy));
            });
            addControlButton(controlsRow, operationButton, true);

            Button themeButton = miniButton(darkMode ? getString(R.string.light) : getString(R.string.dark));
            tintButton(themeButton, "#F1F4F8", "#BCC8D6", "#26384E", "#2B3442", "#56657A", "#F4F7FB");
            makeLandscapeButton(themeButton);
            themeButton.setOnClickListener(view -> {
                darkMode = !darkMode;
                getPreferences(MODE_PRIVATE).edit().putBoolean(PREF_DARK_MODE, darkMode).apply();
                buildLayout();
                refreshEverything(darkMode ? getString(R.string.dark_mode_active) : getString(R.string.light_mode_active));
            });
            addControlButton(controlsRow, themeButton, true);
        }

        historyButton = miniButton(historyExpanded ? getString(R.string.history_close) : getString(R.string.history_open));
        tintButton(historyButton, "#EEF2F7", "#A7B3C4", "#314154", "#263142", "#4B5E76", "#EFF5FF");
        if (landscape) {
            makeLandscapeButton(historyButton);
        } else {
            makeSecondaryPortraitButton(historyButton);
        }
        historyButton.setOnClickListener(view -> {
            historyExpanded = !historyExpanded;
            if (historyButton != null) {
                historyButton.setText(historyExpanded ? getString(R.string.history_close) : getString(R.string.history_open));
            }
            if (historyPanel != null) {
                historyPanel.setVisibility(historyExpanded ? View.VISIBLE : View.GONE);
                rebuildHistoryPanel();
            }
        });

        zipButton = miniButton(getString(R.string.zip));
        tintButton(zipButton, "#FFF4D8", "#E8B84C", "#71500C", "#4B3514", "#8A6425", "#FFE9B0");
        if (landscape) {
            makeLandscapeButton(zipButton);
        } else {
            makeSecondaryPortraitButton(zipButton);
        }
        zipButton.setOnClickListener(view -> createZipFromCurrentSelection());
        addControlButton(controlsRow, zipButton, landscape);
        addControlButton(controlsRow, historyButton, landscape);

        View spacer = new View(this);
        controlsRow.addView(spacer, new LinearLayout.LayoutParams(0, 1, 1f));

        if (landscape) {
            addControlButton(controlsRow, legalButton, true);
            addControlButton(controlsRow, languageButton, true);
        } else {
            Button operationButton = miniButton(moveMode ? getString(R.string.move) : getString(R.string.copy));
            tintButton(operationButton, "#DDF9E9", "#6ECB8B", "#145A2D", "#123B26", "#2B9360", "#D8F8E7");
            operationButton.setOnClickListener(view -> {
                moveMode = !moveMode;
                operationButton.setText(moveMode ? getString(R.string.move) : getString(R.string.copy));
            });
            addControlButton(controlsRow, operationButton, false);

            darkModeSwitch = new Switch(this);
            darkModeSwitch.setText(darkMode ? getString(R.string.light) : getString(R.string.dark));
            darkModeSwitch.setTextColor(color(theme.headerText));
            darkModeSwitch.setTextSize(13);
            darkModeSwitch.setPadding(dp(8), 0, 0, 0);
            darkModeSwitch.setChecked(darkMode);
            darkModeSwitch.setOnCheckedChangeListener((buttonView, checked) -> {
                darkMode = checked;
                darkModeSwitch.setText(darkMode ? getString(R.string.light) : getString(R.string.dark));
                getPreferences(MODE_PRIVATE).edit().putBoolean(PREF_DARK_MODE, darkMode).apply();
                buildLayout();
                refreshEverything(darkMode ? getString(R.string.dark_mode_active) : getString(R.string.light_mode_active));
            });
            controlsRow.addView(darkModeSwitch);
        }
        topBar.addView(controlsRow, new LinearLayout.LayoutParams(
                landscape ? 0 : ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                landscape ? 0.78f : 0f));

        return topBar;
    }

    private void showLegalDialog() {
        new AlertDialog.Builder(this)
                .setTitle(getString(R.string.legal_title))
                .setMessage(getString(R.string.legal_message_full_clean))
                .setPositiveButton("OK", null)
                .show();
    }

    private void showLanguageDialog() {
        String[] codes = {"", "de", "en", "fr", "es", "it", "pt", "nl"};
        String[] labels = {
                getString(R.string.language_system),
                "Deutsch",
                "English",
                "Français",
                "Español",
                "Italiano",
                "Português",
                "Nederlands"
        };
        String current = getPreferences(MODE_PRIVATE).getString(PREF_LANGUAGE, "");
        int checked = 0;
        for (int index = 0; index < codes.length; index++) {
            if (codes[index].equals(current)) {
                checked = index;
                break;
            }
        }
        new AlertDialog.Builder(this)
                .setTitle(getString(R.string.language))
                .setSingleChoiceItems(labels, checked, (dialog, which) -> {
                    getPreferences(MODE_PRIVATE).edit().putString(PREF_LANGUAGE, codes[which]).apply();
                    applyLanguage(codes[which]);
                    dialog.dismiss();
                    buildLayout();
                    refreshEverything(getString(R.string.language_changed));
                })
                .setNegativeButton(getString(R.string.cancel), null)
                .show();
    }

    private void applyLanguage(String code) {
        Locale locale = code == null || code.isEmpty() ? systemLocale : new Locale(code);
        Locale.setDefault(locale);
        Configuration configuration = new Configuration(getResources().getConfiguration());
        configuration.setLocale(locale);
        getResources().updateConfiguration(configuration, getResources().getDisplayMetrics());
    }

    private Button miniButton(String label) {
        Button button = new Button(this);
        button.setText(label);
        button.setTextSize(12);
        button.setTextColor(color(theme.buttonText));
        button.setAllCaps(false);
        button.setMinHeight(0);
        button.setMinWidth(0);
        button.setPadding(dp(10), 0, dp(10), 0);
        button.setGravity(Gravity.CENTER);
        button.setBackground(rounded(theme.buttonBackground, theme.buttonBorder, 1, 8));
        return button;
    }

    private void makeTinyButton(Button button) {
        button.setTextSize(11);
        button.setMinWidth(0);
        button.setMinHeight(0);
        button.setMinimumWidth(0);
        button.setMinimumHeight(0);
        button.setPadding(dp(8), 0, dp(8), 0);
    }

    private void makeSecondaryPortraitButton(Button button) {
        button.setTextSize(11);
        button.setMinWidth(0);
        button.setMinHeight(0);
        button.setMinimumWidth(0);
        button.setMinimumHeight(0);
        button.setPadding(dp(8), 0, dp(8), 0);
    }

    private void makeLandscapeButton(Button button) {
        button.setTextSize(11);
        button.setMinWidth(0);
        button.setMinHeight(0);
        button.setMinimumWidth(0);
        button.setMinimumHeight(0);
        button.setPadding(dp(8), 0, dp(8), 0);
    }

    private void makeLowPriorityButton(Button button) {
        button.setTextSize(9);
        button.setMinWidth(0);
        button.setMinHeight(0);
        button.setMinimumWidth(0);
        button.setMinimumHeight(0);
        button.setPadding(dp(5), 0, dp(5), 0);
    }

    private void addControlButton(LinearLayout row, Button button, boolean landscape) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                landscape ? dp(30) : dp(36));
        params.setMargins(0, 0, dp(4), 0);
        row.addView(button, params);
    }

    private void addHeaderButton(LinearLayout row, Button button) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                dp(26));
        params.setMargins(dp(4), 0, 0, 0);
        row.addView(button, params);
    }

    private void tintButton(Button button,
                            String lightFill, String lightStroke, String lightText,
                            String darkFill, String darkStroke, String darkText) {
        button.setTextColor(color(darkMode ? darkText : lightText));
        button.setBackground(rounded(
                darkMode ? darkFill : lightFill,
                darkMode ? darkStroke : lightStroke,
                1,
                8));
    }

    private File deviceRoot() {
        File start = Environment.getExternalStorageDirectory();
        if (start == null || !start.exists()) {
            start = getFilesDir();
        }
        return start;
    }

    private void refreshEverything(String message) {
        leftPane.refreshFiles();
        leftPane.rebuildTree();
        rightPane.refreshFiles();
        rightPane.rebuildTree();
        updateGlobalStatus(message);
        updateUndoButton();
    }

    private void runFileOperation(CommanderPane sourcePane, FileEntry targetDirectory) {
        if (sourcePane == null || sourcePane.selectedKeys.isEmpty()) {
            updateGlobalStatus(getString(R.string.no_file_selected));
            return;
        }
        if (targetDirectory == null || !targetDirectory.isPhysicalDirectory() || !targetDirectory.file.canWrite()) {
            updateGlobalStatus(getString(R.string.target_not_writable));
            return;
        }

        List<FileEntry> sources = sourcePane.selectedEntries();
        if (sources.isEmpty()) {
            updateGlobalStatus(getString(R.string.no_readable_selection));
            return;
        }
        for (FileEntry source : sources) {
            if (!source.isPhysical()) {
                updateGlobalStatus(getString(R.string.zip_read_only));
                return;
            }
        }

        boolean move = moveMode;
        List<FileEntry> conflicts = conflictingSources(sources, targetDirectory.file, move);
        if (!conflicts.isEmpty()) {
            new AlertDialog.Builder(this)
                    .setTitle(getString(R.string.target_exists_title))
                    .setMessage(getString(R.string.target_exists_message, conflicts.size()))
                    .setPositiveButton(getString(R.string.replace), (dialog, which) ->
                            executeFileOperation(sourcePane, targetDirectory, sources, move, ConflictMode.REPLACE))
                    .setNegativeButton(getString(R.string.keep), (dialog, which) ->
                            executeFileOperation(sourcePane, targetDirectory, sources, move, ConflictMode.KEEP))
                    .setNeutralButton(getString(R.string.cancel), null)
                    .show();
            return;
        }

        executeFileOperation(sourcePane, targetDirectory, sources, move, ConflictMode.KEEP);
    }

    private void createZipFromCurrentSelection() {
        CommanderPane pane = activePane != null && !activePane.selectedKeys.isEmpty() ? activePane : null;
        if (pane == null && !leftPane.selectedKeys.isEmpty()) {
            pane = leftPane;
        }
        if (pane == null && !rightPane.selectedKeys.isEmpty()) {
            pane = rightPane;
        }
        if (pane == null) {
            updateGlobalStatus(getString(R.string.zip_no_selection));
            return;
        }
        if (!pane.currentDirectory.isPhysicalDirectory()) {
            updateGlobalStatus(getString(R.string.zip_current_read_only));
            return;
        }
        List<FileEntry> sources = pane.selectedEntries();
        if (sources.isEmpty()) {
            updateGlobalStatus(getString(R.string.zip_no_selection));
            return;
        }
        for (FileEntry source : sources) {
            if (!source.isPhysical()) {
                updateGlobalStatus(getString(R.string.zip_read_only));
                return;
            }
        }

        CommanderPane sourcePane = pane;
        File zipFile = uniqueFile(sourcePane.currentDirectory.file, "OpenCommander.zip");
        LastOperation operation = new LastOperation(false, prepareBackupRoot(), true);
        showProgress(getString(R.string.zip_creating, sources.size()), 0);

        new Thread(() -> {
            String error = null;
            ProgressCounter counter = new ProgressCounter(sources);
            counter.publish(true);
            try (ZipOutputStream output = new ZipOutputStream(new FileOutputStream(zipFile))) {
                Set<String> usedNames = new HashSet<>();
                for (FileEntry source : sources) {
                    addFileToZip(source.file, source.file.getName(), output, usedNames, counter);
                    counter.itemDone();
                }
                operation.records.add(new OperationRecord(zipFile, zipFile, null));
            } catch (IOException exception) {
                error = exception.getMessage();
                if (zipFile.exists()) {
                    try {
                        deleteRecursive(zipFile);
                    } catch (IOException ignored) {
                        // Best effort cleanup of incomplete archive.
                    }
                }
            }

            String finalError = error;
            runOnUiThread(() -> {
                sourcePane.clearSelection();
                leftPane.reloadTreeKeepingExpansion();
                rightPane.reloadTreeKeepingExpansion();
                leftPane.refreshFiles();
                rightPane.refreshFiles();
                if (finalError == null) {
                    undoHistory.add(0, operation);
                    finishProgress(getString(R.string.zip_created, zipFile.getName()));
                } else {
                    finishProgress(getString(R.string.zip_failed, finalError));
                }
                updateUndoButton();
                rebuildHistoryPanel();
            });
        }).start();
    }

    private void confirmDeleteSelection() {
        CommanderPane pane = selectedPane();
        if (pane == null) {
            updateGlobalStatus(getString(R.string.no_file_selected));
            return;
        }
        List<FileEntry> sources = pane.selectedEntries();
        if (sources.isEmpty()) {
            updateGlobalStatus(getString(R.string.no_readable_selection));
            return;
        }
        for (FileEntry source : sources) {
            if (!source.isPhysical()) {
                updateGlobalStatus(getString(R.string.zip_read_only));
                return;
            }
            File parent = source.file.getParentFile();
            if (parent == null || !parent.canWrite()) {
                updateGlobalStatus(getString(R.string.target_not_writable));
                return;
            }
        }

        CommanderPane sourcePane = pane;
        new AlertDialog.Builder(this)
                .setTitle(getString(R.string.delete_title))
                .setMessage(getString(R.string.delete_message, sources.size()))
                .setPositiveButton(getString(R.string.delete_permanent), (dialog, which) ->
                        executeDeleteOperation(sourcePane, sources, false))
                .setNegativeButton(getString(R.string.trash), (dialog, which) ->
                        executeDeleteOperation(sourcePane, sources, true))
                .setNeutralButton(getString(R.string.cancel), null)
                .show();
    }

    private CommanderPane selectedPane() {
        if (activePane != null && !activePane.selectedKeys.isEmpty()) {
            return activePane;
        }
        if (!leftPane.selectedKeys.isEmpty()) {
            return leftPane;
        }
        if (!rightPane.selectedKeys.isEmpty()) {
            return rightPane;
        }
        return null;
    }

    private void executeDeleteOperation(CommanderPane sourcePane, List<FileEntry> sources, boolean trash) {
        LastOperation operation = new LastOperation(false, prepareBackupRoot(), false, !trash, trash);
        showProgress(getString(R.string.deleting_items, sources.size()), 0);

        new Thread(() -> {
            ProgressCounter counter = new ProgressCounter(sources);
            counter.publish(true);
            int done = 0;
            String error = null;
            for (FileEntry source : sources) {
                try {
                    File sourceFile = source.file;
                    File destination;
                    if (trash) {
                        destination = moveToTrash(sourceFile, counter);
                    } else {
                        destination = backupForDelete(sourceFile, operation.backupRoot, counter);
                    }
                    operation.records.add(new OperationRecord(sourceFile, destination, null));
                    counter.itemDone();
                    done++;
                } catch (IOException exception) {
                    error = exception.getMessage();
                    break;
                }
            }

            int finalDone = done;
            String finalError = error;
            runOnUiThread(() -> {
                sourcePane.clearSelection();
                leftPane.reloadTreeKeepingExpansion();
                rightPane.reloadTreeKeepingExpansion();
                leftPane.refreshFiles();
                rightPane.refreshFiles();
                if (!operation.records.isEmpty()) {
                    undoHistory.add(0, operation);
                    while (undoHistory.size() > 12) {
                        undoHistory.remove(undoHistory.size() - 1);
                    }
                }
                if (finalError == null) {
                    finishProgress(trash ? getString(R.string.trashed_items, finalDone) : getString(R.string.deleted_items, finalDone));
                } else {
                    finishProgress(getString(R.string.error_prefix, finalError));
                }
                updateUndoButton();
                rebuildHistoryPanel();
            });
        }).start();
    }

    private void addFileToZip(File source, String path, ZipOutputStream output,
                              Set<String> usedNames, ProgressCounter counter) throws IOException {
        String safePath = path.replace(File.separatorChar, '/');
        if (source.isDirectory()) {
            String directoryPath = safePath.endsWith("/") ? safePath : safePath + "/";
            if (usedNames.add(directoryPath)) {
                output.putNextEntry(new ZipEntry(directoryPath));
                output.closeEntry();
            }
            File[] children = source.listFiles();
            if (children != null) {
                Arrays.sort(children, Comparator.comparing(file -> file.getName().toLowerCase(Locale.ROOT)));
                for (File child : children) {
                    addFileToZip(child, directoryPath + child.getName(), output, usedNames, counter);
                }
            }
            return;
        }

        String entryName = uniqueZipEntryName(safePath, usedNames);
        ZipEntry entry = new ZipEntry(entryName);
        entry.setTime(source.lastModified());
        output.putNextEntry(entry);
        byte[] buffer = new byte[1024 * 64];
        try (InputStream input = new FileInputStream(source)) {
            int read;
            while ((read = input.read(buffer)) != -1) {
                output.write(buffer, 0, read);
                counter.addBytes(read);
            }
        }
        output.closeEntry();
    }

    private String uniqueZipEntryName(String name, Set<String> usedNames) {
        if (usedNames.add(name)) {
            return name;
        }
        String base = name;
        String extension = "";
        int dot = name.lastIndexOf('.');
        int slash = name.lastIndexOf('/');
        if (dot > slash) {
            base = name.substring(0, dot);
            extension = name.substring(dot);
        }
        int index = 1;
        String candidate;
        do {
            candidate = base + " (" + index + ")" + extension;
            index++;
        } while (!usedNames.add(candidate));
        return candidate;
    }

    private List<FileEntry> conflictingSources(List<FileEntry> sources, File targetFolder, boolean move) {
        List<FileEntry> conflicts = new ArrayList<>();
        for (FileEntry source : sources) {
            File preferredDestination = new File(targetFolder, source.file.getName());
            if (!preferredDestination.exists()) {
                continue;
            }
            if (sameFile(source.file, preferredDestination)) {
                continue;
            }
            if (move && sameFile(source.file.getParentFile(), targetFolder)) {
                continue;
            }
            conflicts.add(source);
        }
        return conflicts;
    }

    private void executeFileOperation(CommanderPane sourcePane, FileEntry targetDirectory,
                                      List<FileEntry> sources, boolean move, ConflictMode conflictMode) {
        LastOperation operation = new LastOperation(move, prepareBackupRoot());
        showProgress(move ? getString(R.string.moving_items, sources.size()) : getString(R.string.copying_items, sources.size()), 0);

        new Thread(() -> {
            ProgressCounter counter = new ProgressCounter(sources);
            counter.publish(true);
            int done = 0;
            String error = null;
            for (FileEntry source : sources) {
                File replacedBackup = null;
                File destination = null;
                try {
                    File sourceFile = source.file;
                    File targetFolder = targetDirectory.file;
                    if (sameFile(sourceFile.getParentFile(), targetFolder)) {
                        continue;
                    }
                    if (sourceFile.isDirectory() && isInside(sourceFile, targetFolder)) {
                        throw new IOException(getString(R.string.cannot_copy_into_self, sourceFile.getName()));
                    }

                    File preferredDestination = new File(targetFolder, sourceFile.getName());
                    if (preferredDestination.exists() && !sameFile(sourceFile, preferredDestination)) {
                        if (conflictMode == ConflictMode.REPLACE) {
                            replacedBackup = backupExistingDestination(preferredDestination, operation.backupRoot);
                            destination = preferredDestination;
                        } else {
                            destination = uniqueFile(targetFolder, sourceFile.getName());
                        }
                    } else if (preferredDestination.exists()) {
                        destination = uniqueFile(targetFolder, sourceFile.getName());
                    } else {
                        destination = preferredDestination;
                    }

                    if (move && sourceFile.renameTo(destination)) {
                        counter.addBytes(Math.max(1L, totalBytes(destination)));
                    } else {
                        copyRecursive(sourceFile, destination, counter);
                        if (move) {
                            deleteRecursive(sourceFile);
                        }
                    }
                    operation.records.add(new OperationRecord(sourceFile, destination, replacedBackup));
                    counter.itemDone();
                    done++;
                } catch (IOException exception) {
                    try {
                        if (destination != null && destination.exists()) {
                            deleteRecursive(destination);
                        }
                        if (replacedBackup != null && replacedBackup.exists() && destination != null) {
                            restoreBackup(replacedBackup, destination);
                        }
                    } catch (IOException ignored) {
                        // Keep the original error visible; best-effort cleanup may fail on locked files.
                    }
                    error = exception.getMessage();
                    break;
                }
            }

            int finalDone = done;
            String finalError = error;
            runOnUiThread(() -> {
                sourcePane.clearSelection();
                leftPane.reloadTreeKeepingExpansion();
                rightPane.reloadTreeKeepingExpansion();
                leftPane.refreshFiles();
                rightPane.refreshFiles();
                if (!operation.records.isEmpty()) {
                    undoHistory.add(0, operation);
                    while (undoHistory.size() > 12) {
                        undoHistory.remove(undoHistory.size() - 1);
                    }
                }
                if (finalError == null) {
                    finishProgress(move ? getString(R.string.moved_items, finalDone) : getString(R.string.copied_items, finalDone));
                } else {
                    finishProgress(getString(R.string.error_prefix, finalError));
                }
                updateUndoButton();
                rebuildHistoryPanel();
            });
        }).start();
    }

    private File prepareBackupRoot() {
        File root = new File(getCacheDir(), "undo_backup_" + SystemClock.elapsedRealtime());
        if (!root.exists()) {
            root.mkdirs();
        }
        return root;
    }

    private File backupExistingDestination(File existing, File backupRoot) throws IOException {
        File backup = uniqueFile(backupRoot, existing.getName());
        copyRecursivePlain(existing, backup);
        deleteRecursive(existing);
        return backup;
    }

    private File backupForDelete(File source, File backupRoot, ProgressCounter counter) throws IOException {
        File backup = uniqueFile(backupRoot, source.getName());
        copyRecursive(source, backup, counter);
        deleteRecursive(source);
        return backup;
    }

    private File moveToTrash(File source, ProgressCounter counter) throws IOException {
        File parent = source.getParentFile();
        if (parent == null) {
            throw new IOException(getString(R.string.cannot_move_to_trash, source.getName()));
        }
        File trashFolder = new File(parent, ".OpenCommanderTrash");
        if (isInside(source, trashFolder)) {
            throw new IOException(getString(R.string.cannot_move_to_trash, source.getName()));
        }
        if (!trashFolder.exists() && !trashFolder.mkdirs()) {
            throw new IOException(getString(R.string.cannot_create_folder, trashFolder.getName()));
        }
        File destination = uniqueFile(trashFolder, source.getName());
        if (source.renameTo(destination)) {
            counter.addBytes(Math.max(1L, totalBytes(destination)));
            return destination;
        }
        copyRecursive(source, destination, counter);
        deleteRecursive(source);
        return destination;
    }

    private void undoNewestOperation() {
        if (undoHistory.isEmpty()) {
            updateGlobalStatus(getString(R.string.undo_empty));
            return;
        }
        undoOperation(undoHistory.get(0));
    }

    private void undoOperation(LastOperation operation) {
        if (operation == null || operation.records.isEmpty()) {
            updateGlobalStatus(getString(R.string.undo_empty_action));
            return;
        }

        showProgress(getString(R.string.undo_progress, operation.label(MainActivity.this)), 0);
        new Thread(() -> {
            String error = null;
            int done = 0;
            List<OperationRecord> records = new ArrayList<>(operation.records);
            Collections.reverse(records);
            ProgressCounter counter = new ProgressCounter(filesFromRecords(records));
            counter.publish(true);

            for (OperationRecord record : records) {
                try {
                    if (operation.move || operation.delete || operation.trash) {
                        File parent = record.original.getParentFile();
                        if (parent != null && !parent.exists() && !parent.mkdirs()) {
                            throw new IOException(getString(R.string.missing_original_folder, parent.getAbsolutePath()));
                        }
                        if (!record.destination.renameTo(record.original)) {
                            copyRecursive(record.destination, record.original, counter);
                            deleteRecursive(record.destination);
                        } else {
                            counter.addBytes(Math.max(1L, totalBytes(record.original)));
                        }
                    } else {
                        deleteRecursive(record.destination);
                        counter.addBytes(1L);
                    }
                    if (record.replacedBackup != null && record.replacedBackup.exists()) {
                        restoreBackup(record.replacedBackup, record.destination);
                    }
                    counter.itemDone();
                    done++;
                } catch (IOException exception) {
                    error = exception.getMessage();
                    break;
                }
            }

            int finalDone = done;
            String finalError = error;
            runOnUiThread(() -> {
                leftPane.reloadTreeKeepingExpansion();
                rightPane.reloadTreeKeepingExpansion();
                leftPane.refreshFiles();
                rightPane.refreshFiles();
                if (finalError == null) {
                    undoHistory.remove(operation);
                    finishProgress(getString(R.string.undo_done, finalDone));
                } else {
                    finishProgress(getString(R.string.undo_failed, finalError));
                }
                updateUndoButton();
                rebuildHistoryPanel();
            });
        }).start();
    }

    private List<FileEntry> filesFromRecords(List<OperationRecord> records) {
        List<FileEntry> files = new ArrayList<>();
        for (OperationRecord record : records) {
            files.add(new FileEntry(record.destination, null));
        }
        return files;
    }

    private void restoreBackup(File backup, File destination) throws IOException {
        if (destination.exists()) {
            deleteRecursive(destination);
        }
        File parent = destination.getParentFile();
        if (parent != null && !parent.exists() && !parent.mkdirs()) {
            throw new IOException(getString(R.string.cannot_create_target_folder, parent.getAbsolutePath()));
        }
        if (!backup.renameTo(destination)) {
            copyRecursivePlain(backup, destination);
            deleteRecursive(backup);
        }
    }

    private void copyRecursive(File source, File destination, ProgressCounter counter) throws IOException {
        if (source.isDirectory()) {
            if (!destination.exists() && !destination.mkdirs()) {
                throw new IOException(getString(R.string.cannot_create_folder, destination.getName()));
            }
            File[] children = source.listFiles();
            if (children != null) {
                for (File child : children) {
                    copyRecursive(child, new File(destination, child.getName()), counter);
                }
            }
            return;
        }

        byte[] buffer = new byte[1024 * 64];
        try (InputStream input = new FileInputStream(source);
             OutputStream output = new FileOutputStream(destination)) {
            int read;
            while ((read = input.read(buffer)) != -1) {
                output.write(buffer, 0, read);
                counter.addBytes(read);
            }
        }
    }

    private void copyRecursivePlain(File source, File destination) throws IOException {
        if (source.isDirectory()) {
            if (!destination.exists() && !destination.mkdirs()) {
                throw new IOException(getString(R.string.cannot_create_folder, destination.getName()));
            }
            File[] children = source.listFiles();
            if (children != null) {
                for (File child : children) {
                    copyRecursivePlain(child, new File(destination, child.getName()));
                }
            }
            return;
        }

        byte[] buffer = new byte[1024 * 64];
        try (InputStream input = new FileInputStream(source);
             OutputStream output = new FileOutputStream(destination)) {
            int read;
            while ((read = input.read(buffer)) != -1) {
                output.write(buffer, 0, read);
            }
        }
    }

    private void deleteRecursive(File file) throws IOException {
        if (file.isDirectory()) {
            File[] children = file.listFiles();
            if (children != null) {
                for (File child : children) {
                    deleteRecursive(child);
                }
            }
        }
        if (!file.delete() && file.exists()) {
            throw new IOException(getString(R.string.cannot_delete, file.getName()));
        }
    }

    private File uniqueFile(File directory, String name) {
        File destination = new File(directory, name);
        if (!destination.exists()) {
            return destination;
        }
        String base = name;
        String extension = "";
        int dot = name.lastIndexOf('.');
        if (dot > 0) {
            base = name.substring(0, dot);
            extension = name.substring(dot);
        }
        int index = 1;
        do {
            destination = new File(directory, base + " (" + index + ")" + extension);
            index++;
        } while (destination.exists());
        return destination;
    }

    private void openExternal(FileEntry entry) {
        try {
            Uri uri = entry.openUri();
            Intent intent = new Intent(Intent.ACTION_VIEW);
            intent.setDataAndType(uri, entry.mimeType());
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            startActivity(Intent.createChooser(intent, entry.name()));
        } catch (Exception exception) {
            Toast.makeText(this, getString(R.string.cannot_open_file), Toast.LENGTH_SHORT).show();
        }
    }

    private String mimeTypeForName(String name) {
        String extension = MimeTypeMap.getFileExtensionFromUrl(name);
        if (extension != null && !extension.isEmpty()) {
            String type = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension.toLowerCase(Locale.ROOT));
            if (type != null) {
                return type;
            }
        }
        return "application/octet-stream";
    }

    private Comparator<FileEntry> entryComparator() {
        return (left, right) -> {
            if (left.isDirectoryLike() != right.isDirectoryLike()) {
                return left.isDirectoryLike() ? -1 : 1;
            }
            return left.name().compareToIgnoreCase(right.name());
        };
    }

    private void requestStorageAccessIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            if (!Environment.isExternalStorageManager()) {
                new AlertDialog.Builder(this)
                        .setTitle(getString(R.string.storage_title))
                        .setMessage(getString(R.string.storage_message))
                        .setPositiveButton(getString(R.string.settings), (dialog, which) -> openAllFilesSettings())
                        .setNegativeButton(getString(R.string.later), null)
                        .show();
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M
                && checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{
                    Manifest.permission.READ_EXTERNAL_STORAGE,
                    Manifest.permission.WRITE_EXTERNAL_STORAGE
            }, REQUEST_STORAGE);
        }
    }

    private void openAllFilesSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return;
        }
        try {
            Intent intent = new Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION);
            intent.setData(Uri.parse("package:" + getPackageName()));
            startActivity(intent);
        } catch (Exception exception) {
            startActivity(new Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION));
        }
    }

    private void showProgress(String message, int progress) {
        runOnUiThread(() -> {
            if (progressText != null) {
                progressText.setText(message);
            }
            if (progressBar != null) {
                progressBar.setVisibility(View.VISIBLE);
                progressBar.setProgress(progress);
            }
            updateGlobalStatus(message);
        });
    }

    private void updateProgress(String message, int progress) {
        runOnUiThread(() -> {
            if (progressText != null) {
                progressText.setText(message);
            }
            if (progressBar != null) {
                progressBar.setVisibility(View.VISIBLE);
                progressBar.setProgress(progress);
            }
        });
    }

    private void finishProgress(String message) {
        if (progressText != null) {
            progressText.setText(message);
        }
        if (progressBar != null) {
            progressBar.setProgress(1000);
        }
        updateGlobalStatus(message);
    }

    private void updateGlobalStatus(String message) {
        if (globalStatus != null && leftPane != null && rightPane != null) {
            globalStatus.setText(getString(R.string.global_status_format,
                    message,
                    leftPane.statusText(),
                    rightPane.statusText()));
        }
    }

    private void updateUndoButton() {
        if (undoButton != null) {
            boolean enabled = !undoHistory.isEmpty();
            undoButton.setEnabled(enabled);
            undoButton.setAlpha(enabled ? 1f : 0.65f);
        }
        if (historyButton != null) {
            historyButton.setText(historyExpanded ? getString(R.string.history_close) : getString(R.string.history_open));
        }
    }

    private void rebuildHistoryPanel() {
        if (historyPanel == null) {
            return;
        }
        historyPanel.removeAllViews();
        if (!historyExpanded) {
            return;
        }
        if (undoHistory.isEmpty()) {
            TextView empty = new TextView(this);
            empty.setText(getString(R.string.history_empty));
            empty.setTextColor(color(theme.secondaryText));
            empty.setTextSize(12);
            historyPanel.addView(empty);
            return;
        }
        for (LastOperation operation : undoHistory) {
            Button item = miniButton(operation.label(MainActivity.this) + "  " + DateFormat.getTimeInstance(DateFormat.SHORT).format(operation.createdAt));
            item.setGravity(Gravity.LEFT | Gravity.CENTER_VERTICAL);
            item.setOnClickListener(view -> undoOperation(operation));
            historyPanel.addView(item, new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT));
        }
    }

    private GradientDrawable rounded(String fill, String stroke, int strokeDp, int radiusDp) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(color(fill));
        drawable.setCornerRadius(dp(radiusDp));
        if (strokeDp > 0) {
            drawable.setStroke(dp(strokeDp), color(stroke));
        }
        return drawable;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private int color(String hex) {
        return Color.parseColor(hex);
    }

    private boolean sameFile(File left, File right) {
        if (left == null || right == null) {
            return false;
        }
        try {
            return left.getCanonicalFile().equals(right.getCanonicalFile());
        } catch (IOException exception) {
            return left.getAbsolutePath().equals(right.getAbsolutePath());
        }
    }

    private boolean isInside(File parent, File child) {
        try {
            String parentPath = parent.getCanonicalPath();
            String childPath = child.getCanonicalPath();
            return childPath.equals(parentPath) || childPath.startsWith(parentPath + File.separator);
        } catch (IOException exception) {
            return false;
        }
    }

    private long totalBytes(File file) {
        if (!file.isDirectory()) {
            return Math.max(1L, file.length());
        }
        long total = 0L;
        File[] children = file.listFiles();
        if (children != null) {
            for (File child : children) {
                total += totalBytes(child);
            }
        }
        return Math.max(1L, total);
    }

    private String readableSize(long bytes) {
        if (bytes < 1024) {
            return bytes + " B";
        }
        double value = bytes / 1024.0;
        String[] units = {"KB", "MB", "GB", "TB"};
        int unit = 0;
        while (value >= 1024 && unit < units.length - 1) {
            value /= 1024.0;
            unit++;
        }
        return String.format(Locale.ROOT, "%.1f %s", value, units[unit]);
    }

    private final class CommanderPane {
        final String title;
        final String accent;
        final List<TreeNode> flatTree = new ArrayList<>();
        final List<FileEntry> visibleEntries = new ArrayList<>();
        final Set<String> selectedKeys = new HashSet<>();

        TreeNode rootNode;
        FileEntry currentDirectory;
        ListView treeList;
        ListView fileList;
        EditText pathText;
        TextView selectionText;
        TreeAdapter treeAdapter;
        FileAdapter fileAdapter;
        int lastClickedPosition = -1;
        long lastClickAt = 0L;
        int touchDragPosition = -1;
        float touchDownX = 0f;
        float touchDownY = 0f;
        boolean touchDragStarted = false;
        long currentDirectoryBytes = -1L;
        int statsGeneration = 0;

        CommanderPane(String title, File root, String accent) {
            this.title = title;
            this.accent = accent;
            setRoot(root);
        }

        void setRoot(File root) {
            currentDirectory = new FileEntry(root, null);
            rootNode = new TreeNode(currentDirectory, 0);
            rootNode.expanded = true;
            loadChildren(rootNode);
            selectedKeys.clear();
        }

        View createView() {
            LinearLayout shell = new LinearLayout(MainActivity.this);
            shell.setOrientation(LinearLayout.VERTICAL);
            shell.setPadding(dp(8), dp(8), dp(8), dp(8));
            shell.setBackground(rounded(theme.panelBackground, theme.panelBorder, 1, 12));

            LinearLayout pathRow = new LinearLayout(MainActivity.this);
            pathRow.setOrientation(LinearLayout.HORIZONTAL);
            pathRow.setGravity(Gravity.CENTER_VERTICAL);

            pathText = new EditText(MainActivity.this);
            pathText.setTextColor(color(theme.secondaryText));
            pathText.setTextSize(11);
            pathText.setSingleLine(true);
            pathText.setPadding(dp(8), dp(6), dp(8), dp(6));
            pathText.setBackground(rounded(theme.pathBackground, theme.pathBorder, 1, 8));
            pathText.setSelectAllOnFocus(true);
            pathText.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
            pathText.setImeOptions(EditorInfo.IME_ACTION_GO);
            pathText.setOnFocusChangeListener((view, hasFocus) -> {
                if (hasFocus) {
                    activePane = this;
                } else {
                    updatePathText();
                }
            });
            pathText.setOnEditorActionListener((view, actionId, event) -> {
                boolean enter = event != null && event.getAction() == android.view.KeyEvent.ACTION_UP
                        && event.getKeyCode() == android.view.KeyEvent.KEYCODE_ENTER;
                if (actionId == EditorInfo.IME_ACTION_GO || enter) {
                    openTypedPath(view.getText().toString());
                    view.clearFocus();
                    return true;
                }
                return false;
            });
            pathRow.addView(pathText, new LinearLayout.LayoutParams(
                    0,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    0.58f));

            selectionText = new TextView(MainActivity.this);
            selectionText.setTextColor(color(theme.secondaryText));
            selectionText.setTextSize(11);
            selectionText.setGravity(Gravity.CENTER);
            selectionText.setSingleLine(true);
            selectionText.setPadding(dp(8), dp(6), dp(8), dp(6));
            selectionText.setBackground(rounded(theme.pathBackground, theme.pathBorder, 1, 8));
            LinearLayout.LayoutParams selectionParams = new LinearLayout.LayoutParams(
                    0,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    0.42f);
            selectionParams.setMargins(dp(6), 0, 0, 0);
            pathRow.addView(selectionText, selectionParams);

            shell.addView(pathRow, new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT));

            LinearLayout columns = new LinearLayout(MainActivity.this);
            columns.setOrientation(LinearLayout.HORIZONTAL);
            columns.setBaselineAligned(false);
            LinearLayout.LayoutParams columnsParams = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    0,
                    1f);
            columnsParams.setMargins(0, dp(6), 0, 0);

            LinearLayout treeColumn = createColumn(getString(R.string.tree), accent);
            treeList = listView(theme.treeBackground);
            treeAdapter = new TreeAdapter(this);
            treeList.setAdapter(treeAdapter);
            treeList.setOnItemClickListener((parent, view, position, id) -> {
                activePane = this;
                TreeNode node = flatTree.get(position);
                currentDirectory = node.entry;
                if (!node.loaded) {
                    loadChildren(node);
                }
                node.expanded = !node.expanded;
                rebuildTree();
                refreshFiles();
                updateGlobalStatus(getString(R.string.folder_changed));
            });
            treeList.setOnDragListener((view, event) -> handleTreeDrop(event));
            treeColumn.addView(treeList, new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    0,
                    1f));

            LinearLayout fileColumn = createColumn(getString(R.string.files), accent);
            fileList = listView(theme.fileBackground);
            fileAdapter = new FileAdapter(this);
            fileList.setAdapter(fileAdapter);
            fileList.setItemsCanFocus(false);
            fileList.setOnItemClickListener((parent, view, position, id) -> handleFileTap(position));
            fileList.setOnItemLongClickListener((parent, view, position, id) -> startFileDrag(position, view));
            fileList.setOnTouchListener((view, event) -> handleFileTouch(event));
            fileList.setOnDragListener((view, event) -> handleFileListDrop(event));
            fileColumn.addView(fileList, new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    0,
                    1f));

            LinearLayout.LayoutParams treeParams = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 0.42f);
            LinearLayout.LayoutParams fileParams = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 0.58f);
            treeParams.setMargins(0, 0, dp(6), 0);
            columns.addView(treeColumn, treeParams);
            columns.addView(fileColumn, fileParams);
            shell.addView(columns, columnsParams);

            refreshFiles();
            rebuildTree();
            return shell;
        }

        private ListView listView(String background) {
            ListView listView = new ListView(MainActivity.this);
            listView.setDividerHeight(1);
            listView.setDivider(new ColorDrawable(color(theme.columnBorder)));
            listView.setCacheColorHint(Color.TRANSPARENT);
            listView.setBackgroundColor(color(background));
            listView.setChoiceMode(ListView.CHOICE_MODE_NONE);
            return listView;
        }

        private LinearLayout createColumn(String label, String accentColor) {
            LinearLayout column = new LinearLayout(MainActivity.this);
            column.setOrientation(LinearLayout.VERTICAL);
            column.setBackground(rounded(theme.columnBackground, theme.columnBorder, 1, 10));

            TextView labelView = new TextView(MainActivity.this);
            labelView.setText(label);
            labelView.setTextColor(color(accentColor));
            labelView.setTextSize(12);
            labelView.setTypeface(Typeface.DEFAULT_BOLD);
            labelView.setGravity(Gravity.CENTER_VERTICAL);
            labelView.setPadding(dp(10), 0, dp(10), 0);
            labelView.setMinHeight(dp(32));
            labelView.setBackgroundColor(color(theme.columnHeaderBackground));
            column.addView(labelView, new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT));
            return column;
        }

        private boolean handleFileTouch(MotionEvent event) {
            switch (event.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    touchDragPosition = fileList.pointToPosition((int) event.getX(), (int) event.getY());
                    touchDownX = event.getX();
                    touchDownY = event.getY();
                    touchDragStarted = false;
                    return false;
                case MotionEvent.ACTION_MOVE:
                    if (touchDragStarted || touchDragPosition < 0 || touchDragPosition >= visibleEntries.size()) {
                        return false;
                    }
                    FileEntry entry = visibleEntries.get(touchDragPosition);
                    if (!selectedKeys.contains(entry.key())) {
                        return false;
                    }
                    float dx = Math.abs(event.getX() - touchDownX);
                    float dy = Math.abs(event.getY() - touchDownY);
                    if (dx < dp(12) && dy < dp(12)) {
                        return false;
                    }
                    int childIndex = touchDragPosition - fileList.getFirstVisiblePosition();
                    View child = fileList.getChildAt(childIndex);
                    if (child == null) {
                        return false;
                    }
                    touchDragStarted = true;
                    startFileDrag(touchDragPosition, child);
                    return true;
                case MotionEvent.ACTION_UP:
                case MotionEvent.ACTION_CANCEL:
                    touchDragPosition = -1;
                    touchDragStarted = false;
                    return false;
                default:
                    return false;
            }
        }

        private boolean startFileDrag(int position, View view) {
            FileEntry entry = visibleEntries.get(position);
            if (!selectedKeys.contains(entry.key())) {
                selectedKeys.add(entry.key());
                fileAdapter.notifyDataSetChanged();
            }
            activePane = this;
            activeDragPane = this;
            ClipData data = ClipData.newPlainText("opencommander-files", String.valueOf(selectedKeys.size()));
            View.DragShadowBuilder shadow = new View.DragShadowBuilder(view);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                view.startDragAndDrop(data, shadow, this, 0);
            } else {
                view.startDrag(data, shadow, this, 0);
            }
            updateSelectionStatus();
            updateGlobalStatus(getString(R.string.items_dragging, selectedKeys.size()));
            return true;
        }

        private boolean handleTreeDrop(DragEvent event) {
            if (!acceptDragEvent(event)) {
                return false;
            }
            if (event.getAction() == DragEvent.ACTION_DROP) {
                int position = treeList.pointToPosition((int) event.getX(), (int) event.getY());
                FileEntry target = position >= 0 && position < flatTree.size()
                        ? flatTree.get(position).entry
                        : currentDirectory;
                runFileOperation(activeDragPane, target);
                activeDragPane = null;
                return true;
            }
            if (event.getAction() == DragEvent.ACTION_DRAG_ENDED) {
                activeDragPane = null;
            }
            return true;
        }

        private boolean handleFileListDrop(DragEvent event) {
            if (!acceptDragEvent(event)) {
                return false;
            }
            if (event.getAction() == DragEvent.ACTION_DROP) {
                runFileOperation(activeDragPane, currentDirectory);
                activeDragPane = null;
                return true;
            }
            if (event.getAction() == DragEvent.ACTION_DRAG_ENDED) {
                activeDragPane = null;
            }
            return true;
        }

        private boolean acceptDragEvent(DragEvent event) {
            switch (event.getAction()) {
                case DragEvent.ACTION_DRAG_STARTED:
                case DragEvent.ACTION_DRAG_ENTERED:
                case DragEvent.ACTION_DRAG_LOCATION:
                case DragEvent.ACTION_DRAG_EXITED:
                case DragEvent.ACTION_DRAG_ENDED:
                case DragEvent.ACTION_DROP:
                    return activeDragPane != null;
                default:
                    return false;
            }
        }

        private void handleFileTap(int position) {
            activePane = this;
            FileEntry entry = visibleEntries.get(position);
            long now = SystemClock.elapsedRealtime();
            if (position == lastClickedPosition && now - lastClickAt <= DOUBLE_TAP_MS) {
                lastClickedPosition = -1;
                lastClickAt = 0L;
                if (entry.isDirectoryLike()) {
                    openDirectory(entry);
                } else {
                    openExternal(entry);
                }
                return;
            }

            if (selectedKeys.contains(entry.key())) {
                selectedKeys.remove(entry.key());
            } else {
                selectedKeys.add(entry.key());
            }
            lastClickedPosition = position;
            lastClickAt = now;
            updateSelectionStatus();
            fileAdapter.notifyDataSetChanged();
            updateGlobalStatus(getString(R.string.selection_updated));
        }

        private void openDirectory(FileEntry directory) {
            activePane = this;
            currentDirectory = directory;
            ensureTreePathVisible(rootNode, directory);
            rebuildTree();
            refreshFiles();
            updateGlobalStatus(getString(R.string.folder_opened));
        }

        private void refreshFiles() {
            visibleEntries.clear();
            visibleEntries.addAll(currentDirectory.children(false));
            selectedKeys.removeIf(key -> findVisible(key) == null);
            currentDirectoryBytes = -1L;
            updatePathText();
            updateSelectionStatus();
            scanDirectorySize();
            if (fileAdapter != null) {
                fileAdapter.notifyDataSetChanged();
            }
        }

        private void scanDirectorySize() {
            int generation = ++statsGeneration;
            FileEntry directory = currentDirectory;
            new Thread(() -> {
                long bytes = directory.contentBytes();
                runOnUiThread(() -> {
                    if (generation == statsGeneration && directory.key().equals(currentDirectory.key())) {
                        currentDirectoryBytes = bytes;
                        updateSelectionStatus();
                    }
                });
            }).start();
        }

        private void openTypedPath(String value) {
            String path = value == null ? "" : value.trim();
            int separator = path.indexOf(" | ");
            if (separator >= 0) {
                path = path.substring(0, separator).trim();
            }
            if (path.endsWith("!/")) {
                path = path.substring(0, path.length() - 2);
            }
            if (path.isEmpty()) {
                updatePathText();
                updateGlobalStatus(getString(R.string.path_empty));
                return;
            }
            File target = new File(path);
            if (!target.exists()) {
                updatePathText();
                updateGlobalStatus(getString(R.string.path_not_found));
                return;
            }
            FileEntry entry = new FileEntry(target, null);
            if (!entry.isDirectoryLike()) {
                updatePathText();
                updateGlobalStatus(getString(R.string.path_not_folder));
                return;
            }
            activePane = this;
            setRoot(target);
            refreshFiles();
            rebuildTree();
            updateGlobalStatus(getString(R.string.folder_opened));
        }

        private void updatePathText() {
            if (pathText != null && !pathText.hasFocus()) {
                pathText.setText(currentDirectory.displayPath());
            }
        }

        private FileEntry findVisible(String key) {
            for (FileEntry entry : visibleEntries) {
                if (entry.key().equals(key)) {
                    return entry;
                }
            }
            return null;
        }

        private void rebuildTree() {
            flatTree.clear();
            addVisibleNode(rootNode);
            if (treeAdapter != null) {
                treeAdapter.notifyDataSetChanged();
            }
        }

        private void addVisibleNode(TreeNode node) {
            flatTree.add(node);
            if (!node.expanded) {
                return;
            }
            if (!node.loaded) {
                loadChildren(node);
            }
            for (TreeNode child : node.children) {
                addVisibleNode(child);
            }
        }

        private void loadChildren(TreeNode node) {
            node.children.clear();
            for (FileEntry entry : node.entry.children(true)) {
                TreeNode child = new TreeNode(entry, node.depth + 1);
                child.expanded = wasExpanded(entry);
                node.children.add(child);
            }
            node.loaded = true;
        }

        private boolean wasExpanded(FileEntry directory) {
            for (TreeNode node : flatTree) {
                if (node.entry.key().equals(directory.key())) {
                    return node.expanded;
                }
            }
            return false;
        }

        private void reloadTreeKeepingExpansion() {
            Set<String> expanded = new HashSet<>();
            for (TreeNode node : flatTree) {
                if (node.expanded) {
                    expanded.add(node.entry.key());
                }
            }
            rootNode = rebuildNode(rootNode.entry, 0, expanded);
            rootNode.expanded = true;
            ensureTreePathVisible(rootNode, currentDirectory);
            rebuildTree();
        }

        private TreeNode rebuildNode(FileEntry entry, int depth, Set<String> expanded) {
            TreeNode node = new TreeNode(entry, depth);
            node.expanded = depth == 0 || expanded.contains(entry.key()) || currentDirectory.key().startsWith(entry.key());
            loadChildren(node);
            return node;
        }

        private boolean ensureTreePathVisible(TreeNode node, FileEntry target) {
            if (node.entry.key().equals(target.key())) {
                node.expanded = true;
                return true;
            }
            if (!target.key().startsWith(node.entry.key())) {
                return false;
            }
            if (!node.loaded) {
                loadChildren(node);
            }
            for (TreeNode child : node.children) {
                if (ensureTreePathVisible(child, target)) {
                    node.expanded = true;
                    return true;
                }
            }
            return false;
        }

        private List<FileEntry> selectedEntries() {
            List<FileEntry> entries = new ArrayList<>();
            for (String key : selectedKeys) {
                FileEntry entry = findVisible(key);
                if (entry != null) {
                    entries.add(entry);
                }
            }
            return entries;
        }

        private void clearSelection() {
            selectedKeys.clear();
            updateSelectionStatus();
            if (fileAdapter != null) {
                fileAdapter.notifyDataSetChanged();
            }
        }

        private void updateSelectionStatus() {
            if (selectionText != null) {
                String size = currentDirectoryBytes >= 0L ? readableSize(currentDirectoryBytes) : "...";
                selectionText.setText(selectedKeys.size() + "/" + visibleEntries.size() + " | " + size);
            }
            updatePathText();
        }

        private String statusText() {
            return getString(R.string.pane_status_format, title, selectedKeys.size(), visibleEntries.size());
        }
    }

    private final class FileEntry {
        final File file;
        final FileEntry parent;
        final String zipPath;
        final boolean zipDirectory;
        final long zipSize;
        final long zipModified;

        FileEntry(File file, FileEntry parent) {
            this(file, parent, null, false, 0L, 0L);
        }

        FileEntry(File file, FileEntry parent, String zipPath, boolean zipDirectory, long zipSize, long zipModified) {
            this.file = file;
            this.parent = parent;
            this.zipPath = zipPath;
            this.zipDirectory = zipDirectory;
            this.zipSize = zipSize;
            this.zipModified = zipModified;
        }

        String key() {
            if (zipPath != null) {
                return physicalKey() + "!/" + zipPath;
            }
            if (isZipArchive()) {
                return physicalKey() + "!/";
            }
            return physicalKey();
        }

        String physicalKey() {
            try {
                return file.getCanonicalPath();
            } catch (IOException exception) {
                return file.getAbsolutePath();
            }
        }

        String name() {
            if (zipPath != null) {
                String normalized = zipPath.endsWith("/") ? zipPath.substring(0, zipPath.length() - 1) : zipPath;
                int slash = normalized.lastIndexOf('/');
                return slash >= 0 ? normalized.substring(slash + 1) : normalized;
            }
            String name = file.getName();
            return name.isEmpty() ? file.getAbsolutePath() : name;
        }

        String mimeType() {
            return isDirectoryLike() ? "resource/folder" : mimeTypeForName(name());
        }

        Uri openUri() {
            if (zipPath != null) {
                File extracted = extractZipEntryForOpen();
                return new Uri.Builder()
                        .scheme("content")
                        .authority(FileContentProvider.AUTHORITY)
                        .encodedPath(Uri.encode(extracted.getAbsolutePath(), "/"))
                        .build();
            }
            return new Uri.Builder()
                    .scheme("content")
                    .authority(FileContentProvider.AUTHORITY)
                    .encodedPath(Uri.encode(file.getAbsolutePath(), "/"))
                    .build();
        }

        boolean isPhysical() {
            return zipPath == null;
        }

        boolean isPhysicalDirectory() {
            return zipPath == null && file.isDirectory();
        }

        boolean isZipArchive() {
            return zipPath == null && file.isFile() && file.getName().toLowerCase(Locale.ROOT).endsWith(".zip");
        }

        boolean isZipEntry() {
            return zipPath != null;
        }

        boolean isDirectoryLike() {
            return file.isDirectory() || isZipArchive() || (zipPath != null && zipDirectory);
        }

        String displayPath() {
            if (zipPath != null) {
                return file.getAbsolutePath() + "!/" + zipPath;
            }
            if (isZipArchive()) {
                return file.getAbsolutePath() + "!/";
            }
            return file.getAbsolutePath();
        }

        long size() {
            return zipPath != null ? zipSize : file.length();
        }

        long modified() {
            return zipPath != null ? zipModified : file.lastModified();
        }

        long contentBytes() {
            if (isZipArchive() || isZipEntry()) {
                return zipContentBytes();
            }
            return totalBytes(file);
        }

        List<FileEntry> children(boolean directoriesOnly) {
            if (isZipArchive() || isZipEntry()) {
                return zipChildren(directoriesOnly);
            }
            File[] files = file.listFiles();
            if (files == null) {
                return Collections.emptyList();
            }
            List<FileEntry> entries = new ArrayList<>();
            for (File child : files) {
                if (!child.canRead()) {
                    continue;
                }
                FileEntry entry = new FileEntry(child, this);
                if (directoriesOnly && !entry.isDirectoryLike()) {
                    continue;
                }
                entries.add(entry);
            }
            Collections.sort(entries, entryComparator());
            return entries;
        }

        private List<FileEntry> zipChildren(boolean directoriesOnly) {
            List<FileEntry> entries = new ArrayList<>();
            String prefix = zipPath == null ? "" : zipPath;
            if (!prefix.isEmpty() && !prefix.endsWith("/")) {
                prefix += "/";
            }
            Set<String> seen = new HashSet<>();
            try (ZipFile zip = new ZipFile(file)) {
                java.util.Enumeration<? extends ZipEntry> zipEntries = zip.entries();
                while (zipEntries.hasMoreElements()) {
                    ZipEntry zipEntry = zipEntries.nextElement();
                    String name = zipEntry.getName();
                    if (name.equals(prefix) || !name.startsWith(prefix)) {
                        continue;
                    }
                    String rest = name.substring(prefix.length());
                    if (rest.isEmpty()) {
                        continue;
                    }
                    int slash = rest.indexOf('/');
                    boolean directory = slash >= 0 || zipEntry.isDirectory();
                    String childPath = slash >= 0 ? prefix + rest.substring(0, slash + 1) : name;
                    if (directoriesOnly && !directory) {
                        continue;
                    }
                    if (!seen.add(childPath)) {
                        continue;
                    }
                    entries.add(new FileEntry(file, this, childPath, directory, zipEntry.getSize(), zipEntry.getTime()));
                }
            } catch (IOException ignored) {
                return Collections.emptyList();
            }
            Collections.sort(entries, entryComparator());
            return entries;
        }

        private long zipContentBytes() {
            long total = 0L;
            String prefix = zipPath == null ? "" : zipPath;
            if (!prefix.isEmpty() && !prefix.endsWith("/")) {
                prefix += "/";
            }
            try (ZipFile zip = new ZipFile(file)) {
                java.util.Enumeration<? extends ZipEntry> zipEntries = zip.entries();
                while (zipEntries.hasMoreElements()) {
                    ZipEntry zipEntry = zipEntries.nextElement();
                    if (zipEntry.isDirectory()) {
                        continue;
                    }
                    String name = zipEntry.getName();
                    if (!prefix.isEmpty() && !name.startsWith(prefix)) {
                        continue;
                    }
                    total += Math.max(0L, zipEntry.getSize());
                }
            } catch (IOException ignored) {
                return 0L;
            }
            return total;
        }

        private File extractZipEntryForOpen() {
            File output = new File(getCacheDir(), "zip_open_" + SystemClock.elapsedRealtime() + "_" + name());
            try (ZipFile zip = new ZipFile(file)) {
                ZipEntry entry = zip.getEntry(zipPath);
                if (entry == null || entry.isDirectory()) {
                    return output;
                }
                try (InputStream input = zip.getInputStream(entry);
                     OutputStream out = new FileOutputStream(output)) {
                    byte[] buffer = new byte[1024 * 64];
                    int read;
                    while ((read = input.read(buffer)) != -1) {
                        out.write(buffer, 0, read);
                    }
                }
            } catch (IOException ignored) {
                // The chooser will fail gracefully if extraction did not succeed.
            }
            return output;
        }
    }

    private final class ProgressCounter {
        final long totalBytes;
        final int totalItems;
        long copiedBytes = 0L;
        int copiedItems = 0;
        long lastUpdate = 0L;

        ProgressCounter(List<FileEntry> entries) {
            long total = 0L;
            for (FileEntry entry : entries) {
                total += totalBytes(entry.file);
            }
            totalBytes = Math.max(1L, total);
            totalItems = Math.max(1, entries.size());
        }

        void addBytes(long bytes) {
            copiedBytes += Math.max(0L, bytes);
            publish(false);
        }

        void itemDone() {
            copiedItems++;
            publish(true);
        }

        private void publish(boolean force) {
            long now = SystemClock.elapsedRealtime();
            if (!force && now - lastUpdate < 150L) {
                return;
            }
            lastUpdate = now;
            int progress = (int) Math.min(1000L, (copiedBytes * 1000L) / totalBytes);
            int percent = progress / 10;
            String message = getString(R.string.progress_format,
                    percent,
                    readableSize(copiedBytes),
                    readableSize(totalBytes),
                    copiedItems,
                    totalItems);
            updateProgress(message, progress);
        }
    }

    private final class TreeAdapter extends BaseAdapter {
        private final CommanderPane pane;

        TreeAdapter(CommanderPane pane) {
            this.pane = pane;
        }

        @Override
        public int getCount() {
            return pane.flatTree.size();
        }

        @Override
        public Object getItem(int position) {
            return pane.flatTree.get(position);
        }

        @Override
        public long getItemId(int position) {
            return position;
        }

        @Override
        public View getView(int position, View convertView, ViewGroup parent) {
            TextView text = convertView instanceof TextView ? (TextView) convertView : new TextView(MainActivity.this);
            TreeNode node = pane.flatTree.get(position);
            text.setTextSize(13);
            text.setTextColor(color(theme.primaryText));
            text.setSingleLine(true);
            text.setGravity(Gravity.CENTER_VERTICAL);
            text.setPadding(dp(10 + node.depth * 14), 0, dp(8), 0);
            text.setMinHeight(dp(42));
            text.setBackgroundColor(node.entry.key().equals(pane.currentDirectory.key())
                    ? color(theme.treeSelection)
                    : Color.TRANSPARENT);
            String marker = node.children.isEmpty() && node.loaded ? "  " : (node.expanded ? "v " : "> ");
            text.setText(marker + node.entry.name());
            return text;
        }
    }

    private final class FileAdapter extends BaseAdapter {
        private final CommanderPane pane;
        private final DateFormat dateFormat = DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT);

        FileAdapter(CommanderPane pane) {
            this.pane = pane;
        }

        @Override
        public int getCount() {
            return pane.visibleEntries.size();
        }

        @Override
        public Object getItem(int position) {
            return pane.visibleEntries.get(position);
        }

        @Override
        public long getItemId(int position) {
            return position;
        }

        @Override
        public View getView(int position, View convertView, ViewGroup parent) {
            RowHolder holder;
            LinearLayout row;
            if (convertView instanceof LinearLayout && convertView.getTag() instanceof RowHolder) {
                row = (LinearLayout) convertView;
                holder = (RowHolder) row.getTag();
            } else {
                row = new LinearLayout(MainActivity.this);
                row.setOrientation(LinearLayout.HORIZONTAL);
                row.setGravity(Gravity.CENTER_VERTICAL);
                row.setPadding(dp(6), dp(5), dp(8), dp(5));
                row.setMinimumHeight(dp(56));
                row.setDescendantFocusability(ViewGroup.FOCUS_BLOCK_DESCENDANTS);
                row.setClickable(false);
                row.setLongClickable(false);

                TypeIconView icon = new TypeIconView(MainActivity.this);
                icon.setFocusable(false);
                row.addView(icon, new LinearLayout.LayoutParams(dp(32), dp(30)));

                LinearLayout texts = new LinearLayout(MainActivity.this);
                texts.setOrientation(LinearLayout.VERTICAL);
                texts.setFocusable(false);
                TextView name = new TextView(MainActivity.this);
                name.setTextColor(color(theme.primaryText));
                name.setTextSize(14);
                name.setSingleLine(true);
                TextView detail = new TextView(MainActivity.this);
                detail.setTextColor(color(theme.secondaryText));
                detail.setTextSize(11);
                detail.setSingleLine(true);
                texts.addView(name);
                texts.addView(detail);
                row.addView(texts, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

                holder = new RowHolder(icon, name, detail);
                row.setTag(holder);
            }

            FileEntry entry = pane.visibleEntries.get(position);
            boolean selected = pane.selectedKeys.contains(entry.key());
            boolean directoryLike = entry.isDirectoryLike();
            holder.icon.setKind(fileIconKind(entry), selected);
            holder.name.setTypeface(directoryLike ? Typeface.DEFAULT_BOLD : Typeface.DEFAULT);
            holder.name.setText(filePrefix(entry) + "  " + entry.name());
            holder.detail.setText(fileDetail(entry));
            row.setBackgroundColor(selected ? color(theme.fileSelection) : Color.TRANSPARENT);
            return row;
        }

        private String filePrefix(FileEntry entry) {
            if (entry.isZipArchive()) {
                return getString(R.string.zip);
            }
            if (entry.isDirectoryLike()) {
                return getString(R.string.folder);
            }
            return getString(R.string.file);
        }

        private String fileIconKind(FileEntry entry) {
            if (entry.isZipArchive()) {
                return "archive";
            }
            if (entry.isDirectoryLike()) {
                return "folder";
            }
            String name = entry.name().toLowerCase(Locale.ROOT);
            String extension = "";
            int dot = name.lastIndexOf('.');
            if (dot >= 0 && dot < name.length() - 1) {
                extension = name.substring(dot + 1);
            }
            String mime = mimeTypeForName(entry.name());
            if ("pdf".equals(extension)) {
                return "pdf";
            }
            if (mime.startsWith("image/")) {
                return "image";
            }
            if (mime.startsWith("video/")) {
                return "video";
            }
            if (mime.startsWith("audio/")) {
                return "audio";
            }
            if ("txt".equals(extension) || "log".equals(extension) || "md".equals(extension)
                    || "rtf".equals(extension)) {
                return "text";
            }
            if ("doc".equals(extension) || "docx".equals(extension) || "odt".equals(extension)
                    || "pages".equals(extension)) {
                return "doc";
            }
            if ("xls".equals(extension) || "xlsx".equals(extension) || "csv".equals(extension)
                    || "ods".equals(extension)) {
                return "sheet";
            }
            if ("ppt".equals(extension) || "pptx".equals(extension) || "odp".equals(extension)
                    || "key".equals(extension)) {
                return "slide";
            }
            if ("apk".equals(extension)) {
                return "apk";
            }
            if ("zip".equals(extension) || "rar".equals(extension) || "7z".equals(extension)
                    || "tar".equals(extension) || "gz".equals(extension) || "bz2".equals(extension)
                    || "xz".equals(extension)) {
                return "archive";
            }
            if ("java".equals(extension) || "kt".equals(extension) || "js".equals(extension)
                    || "ts".equals(extension) || "html".equals(extension) || "css".equals(extension)
                    || "xml".equals(extension) || "json".equals(extension) || "py".equals(extension)
                    || "c".equals(extension) || "cpp".equals(extension) || "h".equals(extension)
                    || "cs".equals(extension) || "php".equals(extension) || "sh".equals(extension)
                    || "bat".equals(extension) || "gradle".equals(extension) || "yml".equals(extension)
                    || "yaml".equals(extension)) {
                return "code";
            }
            if ("db".equals(extension) || "sqlite".equals(extension) || "sql".equals(extension)) {
                return "database";
            }
            if ("ttf".equals(extension) || "otf".equals(extension) || "woff".equals(extension)
                    || "woff2".equals(extension)) {
                return "font";
            }
            return "file";
        }

        private String fileDetail(FileEntry entry) {
            String date = entry.modified() > 0 ? dateFormat.format(entry.modified()) : "";
            if (entry.isZipArchive() || entry.isZipEntry() && entry.isDirectoryLike()) {
                String detail = getString(R.string.zip_detail);
                if (!entry.isDirectoryLike()) {
                    detail = readableSize(entry.size()) + " | " + detail;
                }
                return detail + (date.isEmpty() ? "" : " | " + date);
            }
            if (entry.isDirectoryLike()) {
                return getString(R.string.folder_detail) + (date.isEmpty() ? "" : " | " + date);
            }
            return readableSize(entry.size()) + (date.isEmpty() ? "" : " | " + date);
        }
    }

    private static final class LastOperation {
        final boolean move;
        final boolean zip;
        final boolean delete;
        final boolean trash;
        final File backupRoot;
        final List<OperationRecord> records = new ArrayList<>();
        final long createdAt = System.currentTimeMillis();

        LastOperation(boolean move, File backupRoot) {
            this(move, backupRoot, false);
        }

        LastOperation(boolean move, File backupRoot, boolean zip) {
            this(move, backupRoot, zip, false, false);
        }

        LastOperation(boolean move, File backupRoot, boolean zip, boolean delete, boolean trash) {
            this.move = move;
            this.backupRoot = backupRoot;
            this.zip = zip;
            this.delete = delete;
            this.trash = trash;
        }

        String label(MainActivity activity) {
            if (zip) {
                return activity.getString(R.string.zip_label, records.size());
            }
            if (delete) {
                return activity.getString(R.string.delete_label, records.size());
            }
            if (trash) {
                return activity.getString(R.string.trash_label, records.size());
            }
            return activity.getString(move ? R.string.move_label : R.string.copy_label, records.size());
        }
    }

    private enum ConflictMode {
        KEEP,
        REPLACE
    }

    private static final class OperationRecord {
        final File original;
        final File destination;
        final File replacedBackup;

        OperationRecord(File original, File destination, File replacedBackup) {
            this.original = original;
            this.destination = destination;
            this.replacedBackup = replacedBackup;
        }
    }

    private static final class TreeNode {
        final FileEntry entry;
        final int depth;
        final List<TreeNode> children = new ArrayList<>();
        boolean expanded;
        boolean loaded;

        TreeNode(FileEntry entry, int depth) {
            this.entry = entry;
            this.depth = depth;
        }
    }

    private static final class RowHolder {
        final TypeIconView icon;
        final TextView name;
        final TextView detail;

        RowHolder(TypeIconView icon, TextView name, TextView detail) {
            this.icon = icon;
            this.name = name;
            this.detail = detail;
        }
    }

    private final class TypeIconView extends View {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private String kind = "file";
        private boolean selected;

        TypeIconView(Activity activity) {
            super(activity);
        }

        void setKind(String kind, boolean selected) {
            this.kind = kind == null ? "file" : kind;
            this.selected = selected;
            invalidate();
        }

        @Override
        protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            float width = getWidth();
            float height = getHeight();
            float left = dp(4);
            float top = dp(4);
            float right = width - dp(4);
            float bottom = height - dp(4);
            RectF box = new RectF(left, top, right, bottom);

            if (selected) {
                paint.setStyle(Paint.Style.FILL);
                paint.setColor(color(darkMode ? "#1D4ED8" : "#2F80ED"));
                canvas.drawRoundRect(box, dp(8), dp(8), paint);
                paint.setStyle(Paint.Style.STROKE);
                paint.setStrokeWidth(dp(2));
                paint.setStrokeCap(Paint.Cap.ROUND);
                paint.setStrokeJoin(Paint.Join.ROUND);
                paint.setColor(Color.WHITE);
                Path check = new Path();
                check.moveTo(width * 0.30f, height * 0.52f);
                check.lineTo(width * 0.45f, height * 0.66f);
                check.lineTo(width * 0.72f, height * 0.36f);
                canvas.drawPath(check, paint);
                return;
            }

            paint.setStyle(Paint.Style.FILL);
            paint.setColor(color(iconFill(kind)));
            canvas.drawRoundRect(box, dp(8), dp(8), paint);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(dp(1));
            paint.setColor(color(iconStroke(kind)));
            canvas.drawRoundRect(box, dp(8), dp(8), paint);

            paint.setStrokeCap(Paint.Cap.ROUND);
            paint.setStrokeJoin(Paint.Join.ROUND);
            paint.setStrokeWidth(dp(2));
            paint.setColor(Color.WHITE);
            drawIconGlyph(canvas, kind, box);
        }

        private void drawIconGlyph(Canvas canvas, String kind, RectF box) {
            if ("folder".equals(kind)) {
                drawFolder(canvas, box);
            } else if ("image".equals(kind)) {
                drawImage(canvas, box);
            } else if ("video".equals(kind)) {
                drawVideo(canvas, box);
            } else if ("audio".equals(kind)) {
                drawAudio(canvas, box);
            } else if ("archive".equals(kind)) {
                drawArchive(canvas, box);
            } else if ("apk".equals(kind)) {
                drawApk(canvas, box);
            } else if ("code".equals(kind)) {
                drawTextIcon(canvas, box, "</>");
            } else if ("database".equals(kind)) {
                drawDatabase(canvas, box);
            } else if ("font".equals(kind)) {
                drawTextIcon(canvas, box, "Aa");
            } else if ("pdf".equals(kind)) {
                drawTextIcon(canvas, box, "PDF");
            } else if ("doc".equals(kind)) {
                drawTextIcon(canvas, box, "DOC");
            } else if ("sheet".equals(kind)) {
                drawTextIcon(canvas, box, "XLS");
            } else if ("slide".equals(kind)) {
                drawTextIcon(canvas, box, "PPT");
            } else if ("text".equals(kind)) {
                drawDocument(canvas, box);
                drawTextLines(canvas, box);
            } else {
                drawDocument(canvas, box);
            }
        }

        private void drawFolder(Canvas canvas, RectF box) {
            Path path = new Path();
            path.moveTo(box.left + box.width() * 0.14f, box.top + box.height() * 0.35f);
            path.lineTo(box.left + box.width() * 0.38f, box.top + box.height() * 0.35f);
            path.lineTo(box.left + box.width() * 0.46f, box.top + box.height() * 0.46f);
            path.lineTo(box.right - box.width() * 0.12f, box.top + box.height() * 0.46f);
            path.lineTo(box.right - box.width() * 0.12f, box.bottom - box.height() * 0.18f);
            path.lineTo(box.left + box.width() * 0.14f, box.bottom - box.height() * 0.18f);
            path.close();
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(Color.WHITE);
            canvas.drawPath(path, paint);
        }

        private void drawImage(Canvas canvas, RectF box) {
            RectF frame = new RectF(box.left + box.width() * 0.18f, box.top + box.height() * 0.22f,
                    box.right - box.width() * 0.16f, box.bottom - box.height() * 0.18f);
            paint.setStyle(Paint.Style.STROKE);
            paint.setColor(Color.WHITE);
            paint.setStrokeWidth(dp(2));
            canvas.drawRoundRect(frame, dp(2), dp(2), paint);
            paint.setStyle(Paint.Style.FILL);
            canvas.drawCircle(frame.left + frame.width() * 0.72f, frame.top + frame.height() * 0.28f, dp(2), paint);
            Path mountain = new Path();
            mountain.moveTo(frame.left + frame.width() * 0.12f, frame.bottom - frame.height() * 0.12f);
            mountain.lineTo(frame.left + frame.width() * 0.40f, frame.top + frame.height() * 0.56f);
            mountain.lineTo(frame.left + frame.width() * 0.56f, frame.bottom - frame.height() * 0.18f);
            mountain.lineTo(frame.left + frame.width() * 0.70f, frame.top + frame.height() * 0.48f);
            mountain.lineTo(frame.right - frame.width() * 0.10f, frame.bottom - frame.height() * 0.12f);
            canvas.drawPath(mountain, paint);
        }

        private void drawVideo(Canvas canvas, RectF box) {
            RectF frame = new RectF(box.left + box.width() * 0.18f, box.top + box.height() * 0.24f,
                    box.right - box.width() * 0.16f, box.bottom - box.height() * 0.20f);
            paint.setStyle(Paint.Style.STROKE);
            paint.setColor(Color.WHITE);
            paint.setStrokeWidth(dp(2));
            canvas.drawRoundRect(frame, dp(3), dp(3), paint);
            paint.setStyle(Paint.Style.FILL);
            Path play = new Path();
            play.moveTo(frame.left + frame.width() * 0.40f, frame.top + frame.height() * 0.28f);
            play.lineTo(frame.left + frame.width() * 0.40f, frame.bottom - frame.height() * 0.28f);
            play.lineTo(frame.left + frame.width() * 0.68f, frame.centerY());
            play.close();
            canvas.drawPath(play, paint);
        }

        private void drawAudio(Canvas canvas, RectF box) {
            paint.setStyle(Paint.Style.STROKE);
            paint.setColor(Color.WHITE);
            paint.setStrokeWidth(dp(2));
            float stemX = box.left + box.width() * 0.56f;
            canvas.drawLine(stemX, box.top + box.height() * 0.24f, stemX, box.bottom - box.height() * 0.26f, paint);
            canvas.drawLine(stemX, box.top + box.height() * 0.24f, box.right - box.width() * 0.22f, box.top + box.height() * 0.34f, paint);
            paint.setStyle(Paint.Style.FILL);
            canvas.drawCircle(box.left + box.width() * 0.42f, box.bottom - box.height() * 0.26f, dp(4), paint);
        }

        private void drawArchive(Canvas canvas, RectF box) {
            RectF parcel = new RectF(box.left + box.width() * 0.20f, box.top + box.height() * 0.22f,
                    box.right - box.width() * 0.18f, box.bottom - box.height() * 0.18f);
            paint.setStyle(Paint.Style.STROKE);
            paint.setColor(Color.WHITE);
            paint.setStrokeWidth(dp(2));
            canvas.drawRoundRect(parcel, dp(3), dp(3), paint);
            canvas.drawLine(parcel.centerX(), parcel.top, parcel.centerX(), parcel.bottom, paint);
            canvas.drawLine(parcel.left, parcel.top + parcel.height() * 0.34f, parcel.right, parcel.top + parcel.height() * 0.34f, paint);
        }

        private void drawApk(Canvas canvas, RectF box) {
            paint.setStyle(Paint.Style.STROKE);
            paint.setColor(Color.WHITE);
            paint.setStrokeWidth(dp(2));
            RectF body = new RectF(box.left + box.width() * 0.25f, box.top + box.height() * 0.34f,
                    box.right - box.width() * 0.25f, box.bottom - box.height() * 0.20f);
            canvas.drawRoundRect(body, dp(4), dp(4), paint);
            canvas.drawLine(body.left + dp(2), body.top, body.left - dp(2), body.top - dp(5), paint);
            canvas.drawLine(body.right - dp(2), body.top, body.right + dp(2), body.top - dp(5), paint);
            paint.setStyle(Paint.Style.FILL);
            canvas.drawCircle(body.left + body.width() * 0.34f, body.top + body.height() * 0.32f, dp(1), paint);
            canvas.drawCircle(body.left + body.width() * 0.66f, body.top + body.height() * 0.32f, dp(1), paint);
        }

        private void drawDatabase(Canvas canvas, RectF box) {
            paint.setStyle(Paint.Style.STROKE);
            paint.setColor(Color.WHITE);
            paint.setStrokeWidth(dp(2));
            RectF top = new RectF(box.left + box.width() * 0.22f, box.top + box.height() * 0.22f,
                    box.right - box.width() * 0.22f, box.top + box.height() * 0.46f);
            canvas.drawOval(top, paint);
            canvas.drawLine(top.left, top.centerY(), top.left, box.bottom - box.height() * 0.28f, paint);
            canvas.drawLine(top.right, top.centerY(), top.right, box.bottom - box.height() * 0.28f, paint);
            RectF bottom = new RectF(top.left, box.bottom - box.height() * 0.40f, top.right, box.bottom - box.height() * 0.16f);
            canvas.drawArc(bottom, 0, 180, false, paint);
        }

        private void drawDocument(Canvas canvas, RectF box) {
            Path doc = new Path();
            doc.moveTo(box.left + box.width() * 0.28f, box.top + box.height() * 0.18f);
            doc.lineTo(box.right - box.width() * 0.34f, box.top + box.height() * 0.18f);
            doc.lineTo(box.right - box.width() * 0.18f, box.top + box.height() * 0.34f);
            doc.lineTo(box.right - box.width() * 0.18f, box.bottom - box.height() * 0.16f);
            doc.lineTo(box.left + box.width() * 0.28f, box.bottom - box.height() * 0.16f);
            doc.close();
            paint.setStyle(Paint.Style.STROKE);
            paint.setColor(Color.WHITE);
            paint.setStrokeWidth(dp(2));
            canvas.drawPath(doc, paint);
            canvas.drawLine(box.right - box.width() * 0.34f, box.top + box.height() * 0.18f,
                    box.right - box.width() * 0.34f, box.top + box.height() * 0.34f, paint);
            canvas.drawLine(box.right - box.width() * 0.34f, box.top + box.height() * 0.34f,
                    box.right - box.width() * 0.18f, box.top + box.height() * 0.34f, paint);
        }

        private void drawTextLines(Canvas canvas, RectF box) {
            paint.setStyle(Paint.Style.STROKE);
            paint.setColor(Color.WHITE);
            paint.setStrokeWidth(dp(1));
            float left = box.left + box.width() * 0.36f;
            float right = box.right - box.width() * 0.28f;
            canvas.drawLine(left, box.top + box.height() * 0.48f, right, box.top + box.height() * 0.48f, paint);
            canvas.drawLine(left, box.top + box.height() * 0.60f, right, box.top + box.height() * 0.60f, paint);
        }

        private void drawTextIcon(Canvas canvas, RectF box, String text) {
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(Color.WHITE);
            paint.setTypeface(Typeface.DEFAULT_BOLD);
            paint.setTextAlign(Paint.Align.CENTER);
            paint.setTextSize(text.length() > 2 ? dp(8) : dp(11));
            Paint.FontMetrics metrics = paint.getFontMetrics();
            float baseline = box.centerY() - (metrics.ascent + metrics.descent) / 2f;
            canvas.drawText(text, box.centerX(), baseline, paint);
            paint.setTypeface(Typeface.DEFAULT);
        }

        private String iconFill(String kind) {
            if ("folder".equals(kind)) return "#F2A91B";
            if ("image".equals(kind)) return "#2F80ED";
            if ("video".equals(kind)) return "#7C3AED";
            if ("audio".equals(kind)) return "#10A36F";
            if ("pdf".equals(kind)) return "#E53935";
            if ("doc".equals(kind)) return "#2B6CB0";
            if ("sheet".equals(kind)) return "#16803A";
            if ("slide".equals(kind)) return "#D97706";
            if ("archive".equals(kind)) return "#8B5CF6";
            if ("apk".equals(kind)) return "#16A34A";
            if ("code".equals(kind)) return "#475569";
            if ("database".equals(kind)) return "#0F766E";
            if ("font".equals(kind)) return "#9333EA";
            if ("text".equals(kind)) return "#64748B";
            return "#94A3B8";
        }

        private String iconStroke(String kind) {
            if ("file".equals(kind) || "text".equals(kind) || "code".equals(kind)) {
                return "#CBD5E1";
            }
            return "#FFFFFF";
        }
    }

    private static final class ThemeColors {
        final String appBackground;
        final String headerBackground;
        final String headerText;
        final String panelBackground;
        final String panelBorder;
        final String columnBackground;
        final String columnBorder;
        final String columnHeaderBackground;
        final String pathBackground;
        final String pathBorder;
        final String treeBackground;
        final String fileBackground;
        final String primaryText;
        final String secondaryText;
        final String buttonBackground;
        final String buttonBorder;
        final String buttonText;
        final String fileSelection;
        final String treeSelection;

        ThemeColors(boolean dark) {
            if (dark) {
                appBackground = "#0F172A";
                headerBackground = "#162033";
                headerText = "#F8FAFC";
                panelBackground = "#172033";
                panelBorder = "#334155";
                columnBackground = "#111827";
                columnBorder = "#2D3B4F";
                columnHeaderBackground = "#1F2A3D";
                pathBackground = "#111827";
                pathBorder = "#2D3B4F";
                treeBackground = "#111827";
                fileBackground = "#0B1120";
                primaryText = "#F8FAFC";
                secondaryText = "#C4CEDD";
                buttonBackground = "#23324A";
                buttonBorder = "#40516B";
                buttonText = "#F8FAFC";
                fileSelection = "#1E3A8A";
                treeSelection = "#26344A";
            } else {
                appBackground = "#E9EEF6";
                headerBackground = "#FFFFFF";
                headerText = "#132033";
                panelBackground = "#FFFFFF";
                panelBorder = "#C8D4E3";
                columnBackground = "#F7FAFE";
                columnBorder = "#DDE6F1";
                columnHeaderBackground = "#EEF4FB";
                pathBackground = "#F4F7FB";
                pathBorder = "#DDE6F1";
                treeBackground = "#FAFCFF";
                fileBackground = "#FFFFFF";
                primaryText = "#132033";
                secondaryText = "#5E6F86";
                buttonBackground = "#F1F6FC";
                buttonBorder = "#C7D7EA";
                buttonText = "#183657";
                fileSelection = "#DCEBFF";
                treeSelection = "#E8F0FA";
            }
        }
    }
}
