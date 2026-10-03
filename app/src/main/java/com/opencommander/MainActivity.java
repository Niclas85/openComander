package com.opencommander;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.app.Dialog;
import android.app.UiModeManager;
import android.content.ClipData;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.content.res.Configuration;
import android.database.Cursor;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
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
import android.provider.DocumentsContract;
import android.text.InputType;
import android.view.GestureDetector;
import android.view.DragEvent;
import android.view.Gravity;
import android.view.inputmethod.EditorInfo;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.view.Window;
import android.webkit.MimeTypeMap;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.HorizontalScrollView;
import android.widget.FrameLayout;
import android.widget.ImageView;
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
    private static final int REQUEST_DOCUMENT_TREE = 101;
    private static final long DOUBLE_TAP_MS = 1200L;
    private static final String PREF_DARK_MODE = "dark_mode";
    private static final String PREF_LANGUAGE = "language";
    private static final String PREF_ONBOARDING_SHOWN = "onboarding_shown";
    private static final String PREF_DOCUMENT_TREE = "document_tree";

    private CommanderPane leftPane;
    private CommanderPane rightPane;
    private CommanderPane activeDragPane;
    private Switch darkModeSwitch;
    private Button undoButton;
    private boolean operationInProgress;
    private Button renameButton;
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
    private FileEntry pendingPackageEntry;
    private int baseTopPadding;
    private int baseBottomPadding;
    private boolean storageAccessAtLastBuild;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        SharedPreferences prefs = getPreferences(MODE_PRIVATE);
        applyLanguage(prefs.getString(PREF_LANGUAGE, ""));
        darkMode = prefs.getBoolean(PREF_DARK_MODE, false);
        theme = new ThemeColors(darkMode);
        prefs.edit().remove("left").remove("right").apply();

        FileEntry start = initialRootEntry();
        leftPane = new CommanderPane("1", start, "#1E66C1");
        rightPane = new CommanderPane("2", start, "#1F8A5B");
        buildLayout();
        refreshEverything(storageStatusMessage());
    }

    @Override
    public void onConfigurationChanged(Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        buildLayout();
        refreshEverything(storageStatusMessage());
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (leftPane != null && rightPane != null) {
            boolean hasAccess = hasUsableStorageAccess();
            if (hasAccess != storageAccessAtLastBuild) {
                leftPane.reloadTreeKeepingExpansion();
                rightPane.reloadTreeKeepingExpansion();
                buildLayout();
            }
            refreshEverything(storageStatusMessage());
            if (hasAccess) {
                maybeShowFirstRunHelp();
            }
        }
        if (pendingPackageEntry != null
                && (Build.VERSION.SDK_INT < Build.VERSION_CODES.O
                || getPackageManager().canRequestPackageInstalls())) {
            FileEntry entry = pendingPackageEntry;
            pendingPackageEntry = null;
            launchPackageInstaller(entry);
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
                int left = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
                        ? insets.getInsets(WindowInsets.Type.systemBars()).left
                        : insets.getSystemWindowInsetLeft();
                int right = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
                        ? insets.getInsets(WindowInsets.Type.systemBars()).right
                        : insets.getSystemWindowInsetRight();
                view.setPadding(sidePadding + left, baseTopPadding + top, sidePadding + right, baseBottomPadding + bottom);
                return insets;
            });
        }

        LinearLayout.LayoutParams topBarParams = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
        topBarParams.setMargins(0, 0, 0, portrait ? dp(6) : dp(3));
        root.addView(createTopBar(), topBarParams);

        storageAccessAtLastBuild = hasUsableStorageAccess();
        if (!storageAccessAtLastBuild || Build.VERSION.SDK_INT == Build.VERSION_CODES.Q) {
            LinearLayout.LayoutParams noticeParams = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT);
            noticeParams.setMargins(0, 0, 0, dp(8));
            root.addView(createStorageNotice(), noticeParams);
        }

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
        if (isTelevision() && leftPane.fileList != null) {
            root.post(() -> leftPane.fileList.requestFocus());
        }
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
                landscape ? dp(6) : dp(12),
                landscape ? dp(3) : dp(10),
                landscape ? dp(6) : dp(12),
                landscape ? dp(3) : dp(10));
        topBar.setBackground(rounded(theme.headerBackground, theme.panelBorder, 1, 12));

        LinearLayout titleRow = new LinearLayout(this);
        titleRow.setOrientation(LinearLayout.HORIZONTAL);
        titleRow.setGravity(Gravity.CENTER_VERTICAL);

        TextView title = new TextView(this);
        title.setText(getString(R.string.app_name));
        title.setTextColor(color(theme.headerText));
        title.setTextSize(landscape ? 14 : 20);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        title.setSingleLine(true);
        titleRow.addView(title, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        Button legalButton = miniButton(getString(R.string.legal_short));
        makeLowPriorityButton(legalButton);
        legalButton.setOnClickListener(view -> showLegalDialog());
        if (!landscape) {
            addHeaderButton(titleRow, legalButton);
        }

        Button helpButton = miniButton(getString(R.string.help));
        makeLowPriorityButton(helpButton);
        helpButton.setOnClickListener(view -> showHelpDialog());

        languageButton = miniButton(getString(R.string.language));
        makeLowPriorityButton(languageButton);
        languageButton.setOnClickListener(view -> showLanguageDialog());
        if (!landscape) {
            addHeaderButton(titleRow, languageButton);
        }

        LinearLayout.LayoutParams titleParams = new LinearLayout.LayoutParams(
                landscape ? 0 : ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                landscape ? 0.16f : 0f);
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

        renameButton = miniButton(getString(R.string.rename_button));
        tintButton(renameButton, "#E8F1FF", "#78A9E8", "#174A7E", "#1F344D", "#4F7FAF", "#E8F2FF");
        if (landscape) {
            makeLandscapeButton(renameButton);
        } else {
            makeSecondaryPortraitButton(renameButton);
        }
        renameButton.setOnClickListener(view -> showRenameDialog());
        addControlButton(controlsRow, renameButton, landscape);

        if (landscape) {
            Button operationButton = miniButton(operationModeLabel());
            tintButton(operationButton, "#E9F8EF", "#91D5A7", "#1F6B3A", "#173F2A", "#2D8A50", "#DDFBE8");
            makeLandscapeButton(operationButton);
            operationButton.setOnClickListener(view -> showOperationModeDialog(operationButton));
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
        if (!landscape) {
            addControlButton(controlsRow, helpButton, false);
        }

        View spacer = new View(this);
        controlsRow.addView(spacer, new LinearLayout.LayoutParams(0, 1, 1f));

        if (landscape) {
            addControlButton(controlsRow, legalButton, true);
            addControlButton(controlsRow, helpButton, true);
            addControlButton(controlsRow, languageButton, true);
        } else {
            Button operationButton = miniButton(operationModeLabel());
            tintButton(operationButton, "#DDF9E9", "#6ECB8B", "#145A2D", "#123B26", "#2B9360", "#D8F8E7");
            operationButton.setOnClickListener(view -> showOperationModeDialog(operationButton));
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
        HorizontalScrollView controlsView = new HorizontalScrollView(this);
        controlsView.setHorizontalScrollBarEnabled(true);
        controlsView.setScrollbarFadingEnabled(false);
        controlsView.setFillViewport(false);
        controlsView.addView(controlsRow, new HorizontalScrollView.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));
        topBar.addView(controlsView, new LinearLayout.LayoutParams(
                landscape ? 0 : ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                landscape ? 0.84f : 0f));

        return topBar;
    }

    private View createStorageNotice() {
        boolean portrait = getResources().getConfiguration().orientation == Configuration.ORIENTATION_PORTRAIT;
        LinearLayout notice = new LinearLayout(this);
        notice.setOrientation(portrait ? LinearLayout.VERTICAL : LinearLayout.HORIZONTAL);
        notice.setGravity(Gravity.CENTER_VERTICAL);
        notice.setPadding(dp(12), dp(8), dp(8), dp(8));
        notice.setBackground(rounded(
                darkMode ? "#4A3218" : "#FFF4D6",
                darkMode ? "#A66A22" : "#D99A2B",
                1,
                10));

        TextView message = new TextView(this);
        message.setText(Build.VERSION.SDK_INT == Build.VERSION_CODES.Q
                ? getString(hasUsableStorageAccess()
                        ? R.string.storage_android10_selected_message
                        : R.string.storage_android10_message)
                : getString(R.string.storage_access_required));
        message.setTextColor(color(darkMode ? "#FFE8B0" : "#5F3D00"));
        message.setTextSize(12);
        message.setSingleLine(false);
        LinearLayout.LayoutParams messageParams = portrait
                ? new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                : new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        notice.addView(message, messageParams);

        Button action = miniButton(Build.VERSION.SDK_INT == Build.VERSION_CODES.Q
                ? getString(hasUsableStorageAccess() ? R.string.details : R.string.choose_folder)
                : getString(R.string.grant_access));
        action.setOnClickListener(view -> {
            if (Build.VERSION.SDK_INT == Build.VERSION_CODES.Q && hasUsableStorageAccess()) {
                showAndroid10StorageDialog();
            } else {
                requestStorageAccess();
            }
        });
        LinearLayout.LayoutParams actionParams = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                dp(38));
        actionParams.setMargins(portrait ? 0 : dp(8), portrait ? dp(6) : 0, 0, 0);
        if (portrait) {
            actionParams.gravity = Gravity.END;
        }
        notice.addView(action, actionParams);
        return notice;
    }

    private String operationModeLabel() {
        return getString(moveMode ? R.string.operation_mode_move : R.string.operation_mode_copy);
    }

    private void showOperationModeDialog(Button operationButton) {
        String[] choices = {getString(R.string.copy), getString(R.string.move)};
        new AlertDialog.Builder(this)
                .setTitle(getString(R.string.operation_mode_title))
                .setSingleChoiceItems(choices, moveMode ? 1 : 0, (dialog, which) -> {
                    moveMode = which == 1;
                    operationButton.setText(operationModeLabel());
                    dialog.dismiss();
                    updateGlobalStatus(getString(moveMode
                            ? R.string.operation_mode_move_active
                            : R.string.operation_mode_copy_active));
                })
                .setNegativeButton(getString(R.string.cancel), null)
                .show();
    }

    private void showHelpDialog() {
        new AlertDialog.Builder(this)
                .setTitle(getString(R.string.help_title))
                .setMessage(getString(R.string.help_message)
                        + "\n\n" + getString(R.string.help_access_android)
                        + "\n\n" + getString(R.string.apk_tv_help))
                .setPositiveButton(getString(R.string.understood), null)
                .show();
    }

    private void maybeShowFirstRunHelp() {
        SharedPreferences prefs = getPreferences(MODE_PRIVATE);
        if (prefs.getBoolean(PREF_ONBOARDING_SHOWN, false)) {
            return;
        }
        prefs.edit().putBoolean(PREF_ONBOARDING_SHOWN, true).apply();
        showHelpDialog();
    }

    private void showAndroid10StorageDialog() {
        new AlertDialog.Builder(this)
                .setTitle(getString(R.string.storage_android10_title))
                .setMessage(getString(R.string.storage_android10_details))
                .setPositiveButton(getString(R.string.choose_another_folder), (dialog, which) -> requestStorageAccess())
                .setNegativeButton(getString(R.string.understood), null)
                .show();
    }

    private void showLegalDialog() {
        new AlertDialog.Builder(this)
                .setTitle(getString(R.string.legal_title))
                .setMessage(getString(R.string.legal_message_full_clean))
                .setPositiveButton("OK", null)
                .show();
    }

    private void showLanguageDialog() {
        String[] codes = {"", "de", "en", "fr", "es", "it", "pt", "nl", "zh-Hans", "ja", "ko", "ar", "hi", "ru", "tr", "pl", "id", "vi", "th", "uk", "sv"};
        String[] labels = {
                getString(R.string.language_system),
                "Deutsch",
                "English",
                "Français",
                "Español",
                "Italiano",
                "Português",
                "Nederlands",
                "简体中文",
                "日本語",
                "한국어",
                "العربية",
                "हिन्दी",
                "Русский",
                "Türkçe",
                "Polski",
                "Bahasa Indonesia",
                "Tiếng Việt",
                "ไทย",
                "Українська",
                "Svenska"
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
        Locale locale = code == null || code.isEmpty() ? systemLocale : Locale.forLanguageTag(code);
        Locale.setDefault(locale);
        Configuration configuration = new Configuration(getResources().getConfiguration());
        configuration.setLocale(locale);
        configuration.setLayoutDirection(locale);
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
        applyButtonFocusStyle(button, theme.buttonBackground, theme.buttonBorder);
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
        button.setTextSize(10);
        button.setMinWidth(0);
        button.setMinHeight(0);
        button.setMinimumWidth(0);
        button.setMinimumHeight(0);
        button.setPadding(dp(6), 0, dp(6), 0);
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
                landscape ? dp(28) : dp(36));
        params.setMargins(0, 0, landscape ? dp(3) : dp(4), 0);
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
        String fill = darkMode ? darkFill : lightFill;
        String stroke = darkMode ? darkStroke : lightStroke;
        button.setTextColor(color(darkMode ? darkText : lightText));
        applyButtonFocusStyle(button, fill, stroke);
    }

    private void applyButtonFocusStyle(Button button, String fill, String stroke) {
        button.setBackground(rounded(fill, stroke, 1, 8));
        button.setOnFocusChangeListener((view, hasFocus) -> {
            button.setBackground(rounded(fill, hasFocus ? "#FFD54F" : stroke,
                    hasFocus ? 3 : 1, 8));
        });
    }

    private boolean isTelevision() {
        UiModeManager manager = (UiModeManager) getSystemService(UI_MODE_SERVICE);
        return manager != null && manager.getCurrentModeType() == Configuration.UI_MODE_TYPE_TELEVISION;
    }

    private File deviceRoot() {
        File start = Environment.getExternalStorageDirectory();
        if (start == null || !start.exists()) {
            start = getFilesDir();
        }
        return start;
    }

    private FileEntry initialRootEntry() {
        if (Build.VERSION.SDK_INT == Build.VERSION_CODES.Q) {
            String saved = getPreferences(MODE_PRIVATE).getString(PREF_DOCUMENT_TREE, "");
            if (saved != null && !saved.isEmpty()) {
                FileEntry documentRoot = documentEntryFromTree(Uri.parse(saved));
                if (documentRoot != null) {
                    return documentRoot;
                }
            }
        }
        return new FileEntry(deviceRoot(), null);
    }

    private FileEntry documentEntryFromTree(Uri treeUri) {
        try {
            String rootId = DocumentsContract.getTreeDocumentId(treeUri);
            Uri documentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, rootId);
            return queryDocumentEntry(documentUri, null);
        } catch (Exception exception) {
            return null;
        }
    }

    private FileEntry queryDocumentEntry(Uri documentUri, FileEntry parent) {
        String[] projection = {
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                DocumentsContract.Document.COLUMN_FLAGS
        };
        try (Cursor cursor = getContentResolver().query(documentUri, projection, null, null, null)) {
            if (cursor == null || !cursor.moveToFirst()) {
                return null;
            }
            String name = cursor.getString(0);
            String mime = cursor.getString(1);
            long size = cursor.isNull(2) ? 0L : cursor.getLong(2);
            long modified = cursor.isNull(3) ? 0L : cursor.getLong(3);
            int flags = cursor.isNull(4) ? 0 : cursor.getInt(4);
            return new FileEntry(documentUri, parent, name, mime, size, modified, flags);
        } catch (Exception exception) {
            return null;
        }
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
        if (targetDirectory == null || !targetDirectory.canWriteDirectory()) {
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
        List<FileEntry> conflicts = conflictingSources(sources, targetDirectory, move);
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

    private String archiveNameForSources(List<FileEntry> sources, String currentDirectoryName) {
        String rawName = sources.size() == 1 ? sources.get(0).name() : currentDirectoryName;
        int dot = rawName.lastIndexOf('.');
        String base = sources.size() == 1 && !sources.get(0).isPhysicalDirectory() && dot > 0
                ? rawName.substring(0, dot)
                : rawName;
        return (base.isEmpty() ? "Archive" : base) + ".zip";
    }

    private void createZipFromCurrentSelection() {
        if (operationInProgress) return;
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

        if (pane.currentDirectory.isDocument()) {
            createDocumentZip(pane, sources);
            return;
        }

        CommanderPane sourcePane = pane;
        String requestedZipName = archiveNameForSources(sources, sourcePane.currentDirectory.name());
        File zipFile = uniqueFile(sourcePane.currentDirectory.file, requestedZipName);
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
                output.finish();
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

    private void createDocumentZip(CommanderPane sourcePane, List<FileEntry> sources) {
        FileEntry directory = sourcePane.currentDirectory;
        String zipName = uniqueStorageName(directory, archiveNameForSources(sources, directory.name()));
        LastOperation operation = new LastOperation(false, prepareBackupRoot(), true);
        showProgress(getString(R.string.zip_creating, sources.size()), 0);
        new Thread(() -> {
            FileEntry zipEntry = null;
            String error = null;
            ProgressCounter counter = new ProgressCounter(sources);
            try {
                Uri created = DocumentsContract.createDocument(getContentResolver(), directory.documentUri,
                        "application/zip", zipName);
                zipEntry = created == null ? null : queryDocumentEntry(created, directory);
                if (zipEntry == null) {
                    throw new IOException(getString(R.string.zip_failed, zipName));
                }
                try (OutputStream raw = getContentResolver().openOutputStream(zipEntry.documentUri, "w");
                     ZipOutputStream output = raw == null ? null : new ZipOutputStream(raw)) {
                    if (output == null) {
                        throw new IOException(getString(R.string.zip_failed, zipName));
                    }
                    Set<String> usedNames = new HashSet<>();
                    for (FileEntry source : sources) {
                        addEntryToZip(source, source.name(), output, usedNames, counter);
                        counter.itemDone();
                    }
                }
                operation.storageRecords.add(new StorageOperationRecord(
                        null, null, directory, zipName, zipEntry, null, null));
            } catch (IOException | SecurityException exception) {
                error = exception.getMessage();
                if (zipEntry != null) {
                    try {
                        deleteStorageEntry(zipEntry);
                    } catch (IOException ignored) {
                        // Best effort cleanup of an incomplete archive.
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
                    while (undoHistory.size() > 12) {
                        undoHistory.remove(undoHistory.size() - 1);
                    }
                }
                finishProgress(finalError == null
                        ? getString(R.string.zip_created, zipName)
                        : getString(R.string.zip_failed, finalError));
                updateUndoButton();
                rebuildHistoryPanel();
            });
        }).start();
    }

    private void addEntryToZip(FileEntry source, String path, ZipOutputStream output,
                               Set<String> usedNames, ProgressCounter counter) throws IOException {
        String safePath = path.replace(File.separatorChar, '/');
        if (source.isPhysicalDirectory()) {
            String directoryPath = safePath.endsWith("/") ? safePath : safePath + "/";
            if (usedNames.add(directoryPath)) {
                output.putNextEntry(new ZipEntry(directoryPath));
                output.closeEntry();
            }
            for (FileEntry child : source.children(false)) {
                addEntryToZip(child, directoryPath + child.name(), output, usedNames, counter);
            }
            return;
        }
        String entryName = uniqueZipEntryName(safePath, usedNames);
        ZipEntry entry = new ZipEntry(entryName);
        entry.setTime(source.modified());
        output.putNextEntry(entry);
        try (InputStream input = source.isDocument()
                ? getContentResolver().openInputStream(source.documentUri)
                : new FileInputStream(source.file)) {
            if (input == null) {
                throw new IOException(getString(R.string.no_readable_selection));
            }
            byte[] buffer = new byte[1024 * 64];
            int read;
            while ((read = input.read(buffer)) != -1) {
                output.write(buffer, 0, read);
                if (counter != null) {
                    counter.addBytes(read);
                }
            }
        }
        output.closeEntry();
    }

    private void confirmDeleteSelection() {
        List<CommanderPane> panes = selectedPanes();
        if (panes.isEmpty()) {
            updateGlobalStatus(getString(R.string.no_file_selected));
            return;
        }
        List<FileEntry> sources = selectedEntriesFromPanes(panes);
        if (sources.isEmpty()) {
            updateGlobalStatus(getString(R.string.no_readable_selection));
            return;
        }
        for (FileEntry source : sources) {
            if (!source.isPhysical()) {
                updateGlobalStatus(getString(R.string.zip_read_only));
                return;
            }
            File parent = source.isDocument() ? null : source.file.getParentFile();
            if (source.isDocument()
                    ? source.parent == null || !source.parent.canWriteDirectory()
                    : parent == null || !parent.canWrite()) {
                updateGlobalStatus(getString(R.string.target_not_writable));
                return;
            }
        }

        new AlertDialog.Builder(this)
                .setTitle(getString(R.string.delete_title))
                .setMessage(getString(R.string.delete_message, sources.size()))
                .setPositiveButton(getString(R.string.delete_permanent), (dialog, which) ->
                        executeDeleteOperation(panes, sources, false))
                .setNegativeButton(getString(R.string.trash), (dialog, which) ->
                        executeDeleteOperation(panes, sources, true))
                .setNeutralButton(getString(R.string.cancel), null)
                .show();
    }

    private void showRenameDialog() {
        if (operationInProgress) return;
        List<CommanderPane> panes = selectedPanes();
        List<FileEntry> sources = selectedEntriesFromPanes(panes);
        if (sources.size() != 1) {
            updateGlobalStatus(getString(R.string.rename_single_selection));
            return;
        }

        FileEntry source = sources.get(0);
        if (!source.isPhysical()) {
            updateGlobalStatus(getString(R.string.zip_read_only));
            return;
        }
        File parent = source.isDocument() ? null : source.file.getParentFile();
        if (source.isDocument()
                ? source.parent == null || !source.parent.canWriteDirectory()
                : parent == null || !parent.canWrite()) {
            updateGlobalStatus(getString(R.string.target_not_writable));
            return;
        }

        EditText nameInput = new EditText(this);
        nameInput.setSingleLine(true);
        nameInput.setText(source.name());
        nameInput.setSelectAllOnFocus(true);
        nameInput.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        int dialogPadding = dp(20);
        LinearLayout container = new LinearLayout(this);
        container.setPadding(dialogPadding, 0, dialogPadding, 0);
        container.addView(nameInput, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));

        AlertDialog dialog = new AlertDialog.Builder(this)
                .setTitle(getString(R.string.rename_title))
                .setView(container)
                .setPositiveButton(getString(R.string.rename_button), null)
                .setNegativeButton(getString(R.string.cancel), null)
                .create();
        dialog.setOnShowListener(unused -> {
            nameInput.requestFocus();
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(view -> {
                if (operationInProgress) return;
                String newName = nameInput.getText() == null ? "" : nameInput.getText().toString().trim();
                if (!isValidFileName(newName)) {
                    nameInput.setError(getString(R.string.rename_invalid_name));
                    return;
                }
                if (newName.equals(source.name())) {
                    dialog.dismiss();
                    return;
                }

                if (source.isDocument()) {
                    if (source.parent.findChild(newName) != null) {
                        nameInput.setError(getString(R.string.target_exists_title));
                        return;
                    }
                    try {
                        Uri renamed = DocumentsContract.renameDocument(getContentResolver(), source.documentUri, newName);
                        if (renamed == null) {
                            throw new IOException(getString(R.string.rename_failed));
                        }
                    } catch (IOException | SecurityException exception) {
                        nameInput.setError(getString(R.string.rename_failed));
                        return;
                    }
                    leftPane.ensureDocumentDirectoryReadable();
                    rightPane.ensureDocumentDirectoryReadable();
                } else {
                    File destination = new File(parent, newName);
                    if (destination.exists()) {
                        nameInput.setError(getString(R.string.target_exists_title));
                        return;
                    }
                    try {
                        java.nio.file.Files.move(source.file.toPath(), destination.toPath());
                    } catch (IOException | SecurityException exception) {
                        nameInput.setError(getString(R.string.rename_failed));
                        return;
                    }
                    leftPane.rebaseAfterRename(source.file, destination);
                    rightPane.rebaseAfterRename(source.file, destination);
                }
                leftPane.clearSelection();
                rightPane.clearSelection();
                leftPane.reloadTreeKeepingExpansion();
                rightPane.reloadTreeKeepingExpansion();
                leftPane.refreshFiles();
                rightPane.refreshFiles();
                dialog.dismiss();
                updateGlobalStatus(getString(R.string.renamed_item, newName));
            });
        });
        dialog.show();
    }

    private boolean isValidFileName(String name) {
        return name != null
                && !name.isEmpty()
                && !".".equals(name)
                && !"..".equals(name)
                && name.indexOf('/') < 0
                && name.indexOf('\\') < 0
                && name.indexOf('\0') < 0;
    }

    private List<CommanderPane> selectedPanes() {
        List<CommanderPane> panes = new ArrayList<>();
        if (activePane != null && !activePane.selectedKeys.isEmpty()) {
            panes.add(activePane);
        }
        if (!leftPane.selectedKeys.isEmpty() && leftPane != activePane) {
            panes.add(leftPane);
        }
        if (!rightPane.selectedKeys.isEmpty() && rightPane != activePane) {
            panes.add(rightPane);
        }
        return panes;
    }

    private List<FileEntry> selectedEntriesFromPanes(List<CommanderPane> panes) {
        List<FileEntry> entries = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        for (CommanderPane pane : panes) {
            for (FileEntry entry : pane.selectedEntries()) {
                String key = entry.key();
                if (entry.file != null && entry.isPhysical()) {
                    try {
                        key = entry.file.getCanonicalPath();
                    } catch (IOException ignored) {
                        key = entry.file.getAbsolutePath();
                    }
                }
                if (seen.add(key)) {
                    entries.add(entry);
                }
            }
        }
        return entries;
    }

    private void executeDeleteOperation(List<CommanderPane> sourcePanes, List<FileEntry> sources, boolean trash) {
        if (operationInProgress) return;
        for (FileEntry source : sources) {
            if (source.isDocument()) {
                executeDocumentDeleteOperation(sourcePanes, sources, trash);
                return;
            }
        }
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
                for (CommanderPane pane : sourcePanes) {
                    pane.clearSelection();
                }
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

    private void executeDocumentDeleteOperation(List<CommanderPane> sourcePanes,
                                                List<FileEntry> sources, boolean trash) {
        LastOperation operation = new LastOperation(false, prepareBackupRoot(), false, !trash, trash);
        showProgress(getString(R.string.deleting_items, sources.size()), 0);
        new Thread(() -> {
            ProgressCounter counter = new ProgressCounter(sources);
            int done = 0;
            String error = null;
            for (FileEntry source : sources) {
                try {
                    File backup = backupStorageEntry(source, operation.backupRoot);
                    FileEntry destination = null;
                    if (trash) {
                        if (source.isDocument()) {
                            FileEntry trashFolder = source.parent.findChild(".OpenCommanderTrash");
                            if (trashFolder == null) {
                                trashFolder = createDocumentDirectory(source.parent, ".OpenCommanderTrash");
                            }
                            String name = uniqueStorageName(trashFolder, source.name());
                            destination = copyEntryToDirectory(source, trashFolder, name, counter);
                            deleteStorageEntry(source);
                        } else {
                            File moved = moveToTrash(source.file, counter);
                            destination = new FileEntry(moved, null);
                        }
                    } else {
                        deleteStorageEntry(source);
                    }
                    operation.storageRecords.add(new StorageOperationRecord(
                            source.parent, source.name(), destination == null ? null : destination.parent,
                            destination == null ? null : destination.name(), destination, backup, null));
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
                for (CommanderPane pane : sourcePanes) {
                    pane.clearSelection();
                }
                leftPane.ensureDocumentDirectoryReadable();
                rightPane.ensureDocumentDirectoryReadable();
                leftPane.reloadTreeKeepingExpansion();
                rightPane.reloadTreeKeepingExpansion();
                leftPane.refreshFiles();
                rightPane.refreshFiles();
                if (!operation.storageRecords.isEmpty()) {
                    undoHistory.add(0, operation);
                    while (undoHistory.size() > 12) {
                        undoHistory.remove(undoHistory.size() - 1);
                    }
                }
                if (finalError == null) {
                    finishProgress(trash ? getString(R.string.trashed_items, finalDone)
                            : getString(R.string.deleted_items, finalDone));
                } else {
                    finishProgress(getString(R.string.error_prefix, finalError));
                }
                updateUndoButton();
                rebuildHistoryPanel();
            });
        }).start();
    }

    private FileEntry createDocumentDirectory(FileEntry parent, String name) throws IOException {
        if (parent == null || !parent.isDocument()) {
            throw new IOException(getString(R.string.cannot_create_folder, name));
        }
        try {
            Uri created = DocumentsContract.createDocument(getContentResolver(), parent.documentUri,
                    DocumentsContract.Document.MIME_TYPE_DIR, name);
            FileEntry result = created == null ? null : queryDocumentEntry(created, parent);
            if (result == null) {
                throw new IOException(getString(R.string.cannot_create_folder, name));
            }
            return result;
        } catch (SecurityException exception) {
            throw new IOException(getString(R.string.cannot_create_folder, name), exception);
        }
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
            if (children == null) throw new IOException(getString(R.string.no_readable_selection));
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

    private List<FileEntry> conflictingSources(List<FileEntry> sources, FileEntry targetFolder, boolean move) {
        List<FileEntry> conflicts = new ArrayList<>();
        for (FileEntry source : sources) {
            if (source.isDocument() || targetFolder.isDocument()) {
                FileEntry existing = targetFolder.findChild(source.name());
                if (existing != null && !existing.key().equals(source.key())
                        && !(move && source.parent != null && source.parent.key().equals(targetFolder.key()))) {
                    conflicts.add(source);
                }
            } else {
                File preferredDestination = new File(targetFolder.file, source.file.getName());
                if (!preferredDestination.exists()) {
                    continue;
                }
                if (sameFile(source.file, preferredDestination)) {
                    continue;
                }
                if (move && sameFile(source.file.getParentFile(), targetFolder.file)) {
                    continue;
                }
                conflicts.add(source);
            }
        }
        return conflicts;
    }

    private void executeFileOperation(CommanderPane sourcePane, FileEntry targetDirectory,
                                      List<FileEntry> sources, boolean move, ConflictMode conflictMode) {
        if (operationInProgress) return;
        boolean documentOperation = targetDirectory.isDocument();
        for (FileEntry source : sources) {
            documentOperation |= source.isDocument();
        }
        if (documentOperation) {
            executeDocumentFileOperation(sourcePane, targetDirectory, sources, move, conflictMode);
            return;
        }
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
                            replacedBackup = backupExistingDestination(preferredDestination);
                            destination = preferredDestination;
                        } else {
                            destination = uniqueFile(targetFolder, sourceFile.getName());
                        }
                    } else if (preferredDestination.exists()) {
                        destination = uniqueFile(targetFolder, sourceFile.getName());
                    } else {
                        destination = preferredDestination;
                    }

                    if (move) {
                        moveToNewPath(sourceFile, destination, counter);
                    } else {
                        copyToNewPath(sourceFile, destination, counter);
                    }
                    operation.records.add(new OperationRecord(sourceFile, destination, replacedBackup));
                    counter.itemDone();
                    done++;
                } catch (FileOperationSafety.SourceCleanupException exception) {
                    // Deletion may already have removed part of the source tree.
                    // Retain both the completed destination and any replaced-file backup.
                    error = getString(R.string.move_cleanup_failed, destination.getAbsolutePath())
                            + "\n" + exception.getCause().getMessage();
                    if (replacedBackup != null) {
                        error += "\n" + getString(R.string.recovery_retained, replacedBackup.getAbsolutePath());
                    }
                    break;
                } catch (IOException exception) {
                    error = exception.getMessage();
                    try {
                        // Only private staging files are disposable. An occupied target may
                        // belong to another app, or be the complete copy after a move failure.
                        if (replacedBackup != null && destination != null) {
                            restoreBackup(replacedBackup, destination);
                        }
                    } catch (IOException recoveryError) {
                        error += "\n" + getString(R.string.recovery_retained, replacedBackup.getAbsolutePath())
                                + "\n" + recoveryError.getMessage();
                    }
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

    private void executeDocumentFileOperation(CommanderPane sourcePane, FileEntry targetDirectory,
                                              List<FileEntry> sources, boolean move, ConflictMode conflictMode) {
        LastOperation operation = new LastOperation(move, prepareBackupRoot());
        showProgress(move ? getString(R.string.moving_items, sources.size())
                : getString(R.string.copying_items, sources.size()), 0);
        new Thread(() -> {
            ProgressCounter counter = new ProgressCounter(sources);
            counter.publish(true);
            int done = 0;
            String error = null;
            for (FileEntry source : sources) {
                File sourceBackup = null;
                File replacedBackup = null;
                FileEntry destination = null;
                String destinationName = source.name();
                try {
                    if (source.isPhysicalDirectory() && isEntryInside(source, targetDirectory)) {
                        throw new IOException(getString(R.string.cannot_copy_into_self, source.name()));
                    }
                    if (source.parent != null && source.parent.key().equals(targetDirectory.key())) {
                        continue;
                    }
                    FileEntry existing = targetDirectory.findChild(destinationName);
                    if (existing != null && existing.key().equals(source.key())) {
                        continue;
                    }
                    if (existing != null && conflictMode == ConflictMode.KEEP) {
                        destinationName = uniqueStorageName(targetDirectory, destinationName);
                        existing = null;
                    }

                    if (move) {
                        sourceBackup = backupStorageEntry(source, operation.backupRoot);
                    }
                    if (existing != null) {
                        replacedBackup = backupStorageEntry(existing, operation.backupRoot);
                    }

                    if (existing != null) {
                        String temporaryName = uniqueStorageName(targetDirectory,
                                ".opencommander-" + SystemClock.elapsedRealtime() + "-" + destinationName);
                        destination = copyEntryToDirectory(source, targetDirectory, temporaryName, counter);
                        deleteStorageEntry(existing);
                        destination = renameStorageEntry(destination, destinationName);
                        if (destination == null) {
                            throw new IOException(getString(R.string.rename_failed));
                        }
                    } else {
                        destination = copyEntryToDirectory(source, targetDirectory, destinationName, counter);
                    }

                    if (move) {
                        FileOperationSafety.copyThenDelete(() -> {}, () -> deleteStorageEntry(source));
                    }
                    operation.storageRecords.add(new StorageOperationRecord(
                            source.parent, source.name(), targetDirectory, destinationName,
                            destination, sourceBackup, replacedBackup));
                    counter.itemDone();
                    done++;
                } catch (FileOperationSafety.SourceCleanupException exception) {
                    error = getString(R.string.move_cleanup_failed, destinationName)
                            + "\n" + exception.getCause().getMessage();
                    break;
                } catch (IOException exception) {
                    error = exception.getMessage();
                    try {
                        if (destination != null && storageEntryExists(destination)) {
                            deleteStorageEntry(destination);
                        }
                        if (replacedBackup != null) {
                            restoreStorageBackup(replacedBackup, targetDirectory, destinationName, null);
                        }
                    } catch (IOException recoveryError) {
                        error += "\n" + getString(R.string.recovery_retained, operation.backupRoot.getAbsolutePath())
                                + "\n" + recoveryError.getMessage();
                    }
                    break;
                }
            }

            int finalDone = done;
            String finalError = error;
            runOnUiThread(() -> {
                sourcePane.clearSelection();
                leftPane.ensureDocumentDirectoryReadable();
                rightPane.ensureDocumentDirectoryReadable();
                leftPane.reloadTreeKeepingExpansion();
                rightPane.reloadTreeKeepingExpansion();
                leftPane.refreshFiles();
                rightPane.refreshFiles();
                if (!operation.storageRecords.isEmpty()) {
                    undoHistory.add(0, operation);
                    while (undoHistory.size() > 12) {
                        undoHistory.remove(undoHistory.size() - 1);
                    }
                }
                if (finalError == null) {
                    finishProgress(move ? getString(R.string.moved_items, finalDone)
                            : getString(R.string.copied_items, finalDone));
                } else {
                    finishProgress(getString(R.string.error_prefix, finalError));
                }
                updateUndoButton();
                rebuildHistoryPanel();
            });
        }).start();
    }

    private String uniqueStorageName(FileEntry directory, String name) {
        if (directory.findChild(name) == null) {
            return name;
        }
        String base = name;
        String extension = "";
        int dot = name.lastIndexOf('.');
        if (dot > 0) {
            base = name.substring(0, dot);
            extension = name.substring(dot);
        }
        int index = 1;
        String candidate;
        do {
            candidate = base + " (" + index++ + ")" + extension;
        } while (directory.findChild(candidate) != null);
        return candidate;
    }

    private FileEntry copyEntryToDirectory(FileEntry source, FileEntry targetDirectory,
                                           String destinationName, ProgressCounter counter) throws IOException {
        if (source.file != null && java.nio.file.Files.isSymbolicLink(source.file.toPath())) {
            throw new IOException(getString(R.string.no_readable_selection));
        }
        if (targetDirectory.isDocument()) {
            String mime = source.isPhysicalDirectory()
                    ? DocumentsContract.Document.MIME_TYPE_DIR
                    : source.mimeType();
            Uri created;
            try {
                created = DocumentsContract.createDocument(
                        getContentResolver(), targetDirectory.documentUri, mime, destinationName);
            } catch (Exception exception) {
                throw new IOException(getString(R.string.cannot_create_folder, destinationName), exception);
            }
            if (created == null) {
                throw new IOException(getString(R.string.cannot_create_folder, destinationName));
            }
            FileEntry destination = queryDocumentEntry(created, targetDirectory);
            if (destination == null) {
                throw new IOException(getString(R.string.cannot_create_folder, destinationName));
            }
            if (source.isPhysicalDirectory()) {
                for (FileEntry child : operationChildren(source)) {
                    copyEntryToDirectory(child, destination, child.name(), counter);
                }
            } else {
                copyEntryBytes(source, destination, counter);
            }
            return destination;
        }

        File destinationFile = new File(targetDirectory.file, destinationName);
        if (source.isPhysicalDirectory()) {
            if (!destinationFile.exists() && !destinationFile.mkdirs()) {
                throw new IOException(getString(R.string.cannot_create_folder, destinationName));
            }
            FileEntry destination = new FileEntry(destinationFile, targetDirectory);
            for (FileEntry child : operationChildren(source)) {
                copyEntryToDirectory(child, destination, child.name(), counter);
            }
            return destination;
        }
        FileEntry destination = new FileEntry(destinationFile, targetDirectory);
        copyEntryBytes(source, destination, counter);
        return destination;
    }

    private void copyEntryBytes(FileEntry source, FileEntry destination, ProgressCounter counter) throws IOException {
        try (InputStream input = source.isDocument()
                ? getContentResolver().openInputStream(source.documentUri)
                : new FileInputStream(source.file);
             OutputStream output = destination.isDocument()
                     ? getContentResolver().openOutputStream(destination.documentUri, "w")
                     : new FileOutputStream(destination.file)) {
            if (input == null || output == null) {
                throw new IOException(getString(R.string.no_readable_selection));
            }
            byte[] buffer = new byte[1024 * 64];
            int read;
            while ((read = input.read(buffer)) != -1) {
                output.write(buffer, 0, read);
                if (counter != null) {
                    counter.addBytes(read);
                }
            }
        }
    }

    private void deleteStorageEntry(FileEntry entry) throws IOException {
        if (entry.isDocument()) {
            try {
                if (!DocumentsContract.deleteDocument(getContentResolver(), entry.documentUri)) {
                    throw new IOException(getString(R.string.cannot_delete, entry.name()));
                }
            } catch (SecurityException exception) {
                throw new IOException(getString(R.string.cannot_delete, entry.name()), exception);
            }
            return;
        }
        deleteRecursive(entry.file);
    }

    private FileEntry renameDocumentEntry(FileEntry entry, String newName) throws IOException {
        if (!entry.isDocument()) {
            return null;
        }
        try {
            Uri renamed = DocumentsContract.renameDocument(getContentResolver(), entry.documentUri, newName);
            return renamed == null ? null : queryDocumentEntry(renamed, entry.parent);
        } catch (SecurityException exception) {
            throw new IOException(getString(R.string.rename_failed), exception);
        }
    }

    private FileEntry renameStorageEntry(FileEntry entry, String newName) throws IOException {
        if (entry.isDocument()) {
            return renameDocumentEntry(entry, newName);
        }
        File parent = entry.file.getParentFile();
        if (parent == null) {
            throw new IOException(getString(R.string.rename_failed));
        }
        File renamed = new File(parent, newName);
        try {
            java.nio.file.Files.move(entry.file.toPath(), renamed.toPath());
        } catch (IOException | SecurityException exception) {
            throw new IOException(getString(R.string.rename_failed), exception);
        }
        return new FileEntry(renamed, entry.parent);
    }

    private File backupStorageEntry(FileEntry source, File backupRoot) throws IOException {
        File backup = uniqueFile(backupRoot, source.name());
        FileEntry backupDirectory = new FileEntry(backupRoot, null);
        FileEntry copied = copyEntryToDirectory(source, backupDirectory, backup.getName(), null);
        return copied.file;
    }

    private FileEntry restoreStorageBackup(File backup, FileEntry parent, String name,
                                           ProgressCounter counter) throws IOException {
        if (backup == null || !backup.exists() || parent == null) {
            throw new IOException(getString(R.string.undo_empty_action));
        }
        FileEntry existing = parent.findChild(name);
        if (existing != null) {
            throw new IOException(getString(R.string.target_exists_title));
        }
        return copyEntryToDirectory(new FileEntry(backup, null), parent, name, counter);
    }

    private byte[] captureSnapshot(FileEntry entry) {
        try {
            return FileOperationSafety.snapshot(snapshotNode(entry));
        } catch (IOException | SecurityException error) {
            // Keep the successful operation, but never authorize an unverifiable undo.
            return null;
        }
    }

    private void requireUnchanged(byte[] expected, FileEntry entry) throws IOException {
        try {
            if (!FileOperationSafety.unchanged(expected, snapshotNode(entry))) {
                throw new IOException(getString(R.string.undo_changed));
            }
        } catch (SecurityException error) {
            throw new IOException(getString(R.string.undo_changed), error);
        }
    }

    private List<FileEntry> operationChildren(FileEntry entry) throws IOException {
        List<FileEntry> result = new ArrayList<>();
        if (!entry.isDocument()) {
            File[] children = entry.file.listFiles();
            if (children == null) throw new IOException(getString(R.string.no_readable_selection));
            for (File child : children) result.add(new FileEntry(child, entry));
        } else {
            Uri uri = DocumentsContract.buildChildDocumentsUriUsingTree(entry.documentUri,
                    DocumentsContract.getDocumentId(entry.documentUri));
            // UI listings may hide provider failures; destructive operations must not.
            try (Cursor cursor = getContentResolver().query(uri,
                    new String[]{DocumentsContract.Document.COLUMN_DOCUMENT_ID}, null, null, null)) {
                if (cursor == null || cursor.getExtras().getBoolean(DocumentsContract.EXTRA_LOADING, false)
                        || cursor.getExtras().containsKey(DocumentsContract.EXTRA_ERROR)) {
                    throw new IOException(getString(R.string.no_readable_selection));
                }
                while (cursor.moveToNext()) {
                    Uri child = DocumentsContract.buildDocumentUriUsingTree(entry.documentUri, cursor.getString(0));
                    FileEntry childEntry = queryDocumentEntry(child, entry);
                    if (childEntry == null) throw new IOException(getString(R.string.no_readable_selection));
                    result.add(childEntry);
                }
            } catch (RuntimeException error) {
                throw new IOException(getString(R.string.no_readable_selection), error);
            }
        }
        return result;
    }

    private FileOperationSafety.Node snapshotNode(FileEntry original) throws IOException {
        FileEntry entry = original.isDocument()
                ? queryDocumentEntry(original.documentUri, original.parent) : original;
        if (entry == null) throw new IOException(getString(R.string.undo_changed));
        return new FileOperationSafety.Node() {
            public String name() { return entry.name(); }
            public String identity() throws IOException {
                if (entry.isDocument()) {
                    return entry.documentUri + ":" + entry.documentModified + ":" + entry.documentSize;
                }
                java.nio.file.attribute.BasicFileAttributes attributes = java.nio.file.Files.readAttributes(
                        entry.file.toPath(), java.nio.file.attribute.BasicFileAttributes.class,
                        java.nio.file.LinkOption.NOFOLLOW_LINKS);
                if (attributes.isSymbolicLink() || (!attributes.isDirectory() && !attributes.isRegularFile())) {
                    throw new IOException(getString(R.string.undo_changed));
                }
                return attributes.fileKey() + ":" + attributes.lastModifiedTime() + ":" + attributes.size();
            }
            public boolean directory() { return entry.isPhysicalDirectory(); }
            public List<FileOperationSafety.Node> children() throws IOException {
                List<FileOperationSafety.Node> result = new ArrayList<>();
                for (FileEntry child : operationChildren(entry)) result.add(snapshotNode(child));
                return result;
            }
            public InputStream open() throws IOException {
                return entry.isDocument() ? getContentResolver().openInputStream(entry.documentUri)
                        : new FileInputStream(entry.file);
            }
        };
    }

    private boolean storageEntryExists(FileEntry entry) {
        if (entry == null) {
            return false;
        }
        if (entry.isDocument()) {
            return queryDocumentEntry(entry.documentUri, entry.parent) != null;
        }
        return entry.file != null && entry.file.exists();
    }

    private File prepareBackupRoot() {
        File root = new File(getCacheDir(), "undo_backup_" + SystemClock.elapsedRealtime());
        if (!root.exists()) {
            root.mkdirs();
        }
        return root;
    }

    private File backupExistingDestination(File existing) throws IOException {
        File directory = java.nio.file.Files.createTempDirectory(
                existing.getParentFile().toPath(), ".OpenCommanderUndo-").toFile();
        File backup = new File(directory, existing.getName());
        java.nio.file.Files.move(existing.toPath(), backup.toPath());
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
        if (operationInProgress) return;
        if (operation == null || operation.recordCount() == 0) {
            updateGlobalStatus(getString(R.string.undo_empty_action));
            return;
        }
        if (!operation.storageRecords.isEmpty()) {
            undoStorageOperation(operation);
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
                    if (!record.destinationReverted) {
                        requireUnchanged(record.destinationSnapshot, new FileEntry(record.destination, null));
                        if (operation.move || operation.delete || operation.trash) {
                            if (java.nio.file.Files.exists(record.original.toPath(), java.nio.file.LinkOption.NOFOLLOW_LINKS)) {
                                throw new IOException(getString(R.string.target_exists_title));
                            }
                            File parent = record.original.getParentFile();
                            if (parent != null && !parent.exists() && !parent.mkdirs()) {
                                throw new IOException(getString(R.string.missing_original_folder, parent.getAbsolutePath()));
                            }
                            // Never merge into or overwrite a newly created source path.
                            try {
                                moveToNewPath(record.destination, record.original, counter);
                            } catch (FileOperationSafety.SourceCleanupException cleanupError) {
                                record.destinationReverted = true;
                                throw new IOException(getString(R.string.move_cleanup_failed,
                                        record.original.getAbsolutePath()), cleanupError);
                            }
                        } else {
                            // Rename into private recovery storage before any cleanup. This also
                            // preserves edits made externally between verification and the rename.
                            File recoveryRoot = java.nio.file.Files.createTempDirectory(
                                    record.destination.getParentFile().toPath(), ".OpenCommanderUndo-").toFile();
                            File recovery = new File(recoveryRoot, record.destination.getName());
                            java.nio.file.Files.move(record.destination.toPath(), recovery.toPath());
                        }
                        record.destinationReverted = true;
                    }
                    if (record.replacedBackup != null) {
                        restoreBackup(record.replacedBackup, record.destination);
                    }
                    operation.records.remove(record);
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

    private void undoStorageOperation(LastOperation operation) {
        showProgress(getString(R.string.undo_progress, operation.label(MainActivity.this)), 0);
        new Thread(() -> {
            String error = null;
            int done = 0;
            List<StorageOperationRecord> records = new ArrayList<>(operation.storageRecords);
            Collections.reverse(records);
            List<FileEntry> progressEntries = new ArrayList<>();
            for (StorageOperationRecord record : records) {
                if (record.sourceBackup != null) {
                    progressEntries.add(new FileEntry(record.sourceBackup, null));
                } else if (record.destination != null) {
                    progressEntries.add(record.destination);
                }
            }
            ProgressCounter counter = new ProgressCounter(progressEntries);
            counter.publish(true);

            for (StorageOperationRecord record : records) {
                try {
                    if (!record.destinationReverted && record.destination != null) {
                        requireUnchanged(record.destinationSnapshot, record.destination);
                    }
                    // Restore the source before removing the destination. A conflict or
                    // failed provider write must leave the complete destination intact.
                    if (record.sourceBackup != null && !record.sourceRestored) {
                        restoreStorageBackup(record.sourceBackup, record.originalParent,
                                record.originalName, counter);
                        record.sourceRestored = true;
                    }
                    if (!record.destinationReverted && record.destination != null) {
                        backupStorageEntry(record.destination, operation.backupRoot);
                        deleteStorageEntry(record.destination);
                        record.destinationReverted = true;
                    }
                    if (record.replacedBackup != null) {
                        restoreStorageBackup(record.replacedBackup, record.targetParent,
                                record.destinationName, counter);
                    }
                    operation.storageRecords.remove(record);
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
                leftPane.ensureDocumentDirectoryReadable();
                rightPane.ensureDocumentDirectoryReadable();
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
        if (java.nio.file.Files.exists(destination.toPath(), java.nio.file.LinkOption.NOFOLLOW_LINKS)) {
            throw new IOException(getString(R.string.target_exists_title));
        }
        File parent = destination.getParentFile();
        if (parent != null && !parent.exists() && !parent.mkdirs()) {
            throw new IOException(getString(R.string.cannot_create_target_folder, parent.getAbsolutePath()));
        }
        // Replacement backups live on the same volume. Renaming preserves identity,
        // symlinks and metadata, and never overwrites an occupied destination.
        java.nio.file.Files.move(backup.toPath(), destination.toPath());
    }

    private void copyToNewPath(File source, File destination, ProgressCounter counter) throws IOException {
        FileOperationSafety.copyToNewPath(source, destination, (from, to) -> {
            if (counter == null) copyRecursivePlain(from, to);
            else copyRecursive(from, to, counter);
        });
    }

    private void moveToNewPath(File source, File destination, ProgressCounter counter) throws IOException {
        FileOperationSafety.moveToNewPath(source, destination, (from, to) -> {
            if (counter == null) copyRecursivePlain(from, to);
            else copyRecursive(from, to, counter);
        }, this::deleteRecursive);
    }

    private void copyRecursive(File source, File destination, ProgressCounter counter) throws IOException {
        if (java.nio.file.Files.isSymbolicLink(source.toPath())) {
            throw new IOException(getString(R.string.no_readable_selection));
        }
        if (source.isDirectory()) {
            if (!destination.exists() && !destination.mkdirs()) {
                throw new IOException(getString(R.string.cannot_create_folder, destination.getName()));
            }
            File[] children = source.listFiles();
            if (children == null) throw new IOException(getString(R.string.no_readable_selection));
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
        if (java.nio.file.Files.isSymbolicLink(source.toPath())) {
            throw new IOException(getString(R.string.no_readable_selection));
        }
        if (source.isDirectory()) {
            if (!destination.exists() && !destination.mkdirs()) {
                throw new IOException(getString(R.string.cannot_create_folder, destination.getName()));
            }
            File[] children = source.listFiles();
            if (children == null) throw new IOException(getString(R.string.no_readable_selection));
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
        if (!java.nio.file.Files.isSymbolicLink(file.toPath()) && file.isDirectory()) {
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
        if (entry.isApkPackage()) {
            openApkPackage(entry);
            return;
        }
        if (isImageEntry(entry)) {
            List<FileEntry> entries = activePane == null
                    ? Collections.singletonList(entry)
                    : activePane.visibleEntries;
            openImageViewer(entry, entries);
            return;
        }
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

    private boolean isImageEntry(FileEntry entry) {
        return entry != null && !entry.isDirectoryLike() && entry.mimeType().startsWith("image/");
    }

    private void openImageViewer(FileEntry selected, List<FileEntry> folderEntries) {
        List<FileEntry> images = new ArrayList<>();
        for (FileEntry entry : folderEntries) {
            if (isImageEntry(entry)) {
                images.add(entry);
            }
        }
        int selectedIndex = -1;
        for (int index = 0; index < images.size(); index++) {
            if (images.get(index).key().equals(selected.key())) {
                selectedIndex = index;
                break;
            }
        }
        if (selectedIndex < 0) {
            images.add(selected);
            selectedIndex = images.size() - 1;
        }
        new ImageViewerDialog(images, selectedIndex).show();
    }

    private final class ImageViewerDialog extends Dialog {
        private final List<FileEntry> images;
        private final ImageView imageView;
        private final TextView titleView;
        private final TextView pageView;
        private final TextView errorView;
        private int index;
        private int loadGeneration;
        private Bitmap displayedBitmap;

        ImageViewerDialog(List<FileEntry> images, int index) {
            super(MainActivity.this, android.R.style.Theme_Material_NoActionBar_Fullscreen);
            this.images = new ArrayList<>(images);
            this.index = index;

            FrameLayout root = new FrameLayout(MainActivity.this);
            root.setBackgroundColor(Color.BLACK);
            root.setContentDescription("ImageViewer");

            imageView = new ImageView(MainActivity.this);
            imageView.setScaleType(ImageView.ScaleType.FIT_CENTER);
            imageView.setAdjustViewBounds(false);
            imageView.setContentDescription("ImageViewerImage");
            imageView.setPadding(dp(8), dp(64), dp(8), dp(20));
            root.addView(imageView, new FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

            errorView = new TextView(MainActivity.this);
            errorView.setTextColor(Color.WHITE);
            errorView.setTextSize(16);
            errorView.setGravity(Gravity.CENTER);
            errorView.setVisibility(View.GONE);
            errorView.setContentDescription("ImageViewerError");
            root.addView(errorView, new FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

            View gestureLayer = new View(MainActivity.this);
            gestureLayer.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
            root.addView(gestureLayer, new FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

            LinearLayout header = new LinearLayout(MainActivity.this);
            header.setOrientation(LinearLayout.HORIZONTAL);
            header.setGravity(Gravity.CENTER_VERTICAL);
            header.setPadding(dp(8), dp(4), dp(12), dp(4));
            header.setBackgroundColor(Color.argb(210, 20, 20, 20));

            Button close = new Button(MainActivity.this);
            close.setText("\u2715");
            close.setTextColor(Color.WHITE);
            close.setTextSize(22);
            close.setBackgroundColor(Color.TRANSPARENT);
            close.setContentDescription("ImageViewerClose");
            close.setOnClickListener(view -> dismiss());
            header.addView(close, new LinearLayout.LayoutParams(dp(56), dp(56)));

            titleView = new TextView(MainActivity.this);
            titleView.setTextColor(Color.WHITE);
            titleView.setTextSize(15);
            titleView.setSingleLine(true);
            titleView.setEllipsize(android.text.TextUtils.TruncateAt.MIDDLE);
            titleView.setContentDescription("ImageViewerTitle");
            header.addView(titleView, new LinearLayout.LayoutParams(0, dp(56), 1f));

            pageView = new TextView(MainActivity.this);
            pageView.setTextColor(Color.WHITE);
            pageView.setTextSize(14);
            pageView.setGravity(Gravity.CENTER);
            pageView.setContentDescription("ImageViewerPage");
            header.addView(pageView, new LinearLayout.LayoutParams(dp(64), dp(56)));

            FrameLayout.LayoutParams headerParams = new FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP);
            root.addView(header, headerParams);

            gestureLayer.setOnTouchListener(new View.OnTouchListener() {
                private float downX;
                private float downY;

                @Override
                public boolean onTouch(View view, MotionEvent event) {
                    if (event.getActionMasked() == MotionEvent.ACTION_DOWN) {
                        downX = event.getX();
                        downY = event.getY();
                        return true;
                    }
                    if (event.getActionMasked() == MotionEvent.ACTION_UP) {
                        float distanceX = event.getX() - downX;
                        float distanceY = event.getY() - downY;
                        if (Math.abs(distanceX) >= dp(48)
                                && Math.abs(distanceX) > Math.abs(distanceY)) {
                            showIndex(ImageViewerDialog.this.index + (distanceX < 0 ? 1 : -1));
                        }
                        return true;
                    }
                    return event.getActionMasked() == MotionEvent.ACTION_MOVE;
                }
            });
            setContentView(root);
            setOnDismissListener(dialog -> clearBitmap());
        }

        @Override
        public void show() {
            super.show();
            Window window = getWindow();
            if (window != null) {
                window.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
                window.setStatusBarColor(Color.BLACK);
                window.setNavigationBarColor(Color.BLACK);
            }
            showIndex(index);
        }

        private void showIndex(int requestedIndex) {
            if (requestedIndex < 0 || requestedIndex >= images.size() || requestedIndex == index && displayedBitmap != null) {
                return;
            }
            index = requestedIndex;
            FileEntry entry = images.get(index);
            titleView.setText(entry.name());
            pageView.setText((index + 1) + " / " + images.size());
            imageView.setContentDescription("ImageViewerImage " + entry.name());
            imageView.setImageDrawable(null);
            errorView.setVisibility(View.GONE);
            int generation = ++loadGeneration;
            new Thread(() -> {
                Bitmap bitmap = decodeViewerBitmap(entry);
                runOnUiThread(() -> {
                    if (!isShowing() || generation != loadGeneration) {
                        if (bitmap != null) bitmap.recycle();
                        return;
                    }
                    clearBitmap();
                    displayedBitmap = bitmap;
                    if (bitmap == null) {
                        errorView.setText(getString(R.string.cannot_open_file));
                        errorView.setVisibility(View.VISIBLE);
                    } else {
                        imageView.setImageBitmap(bitmap);
                    }
                });
            }, "image-viewer-loader").start();
        }

        private Bitmap decodeViewerBitmap(FileEntry entry) {
            int width = Math.max(1, getResources().getDisplayMetrics().widthPixels * 2);
            int height = Math.max(1, getResources().getDisplayMetrics().heightPixels * 2);
            try {
                BitmapFactory.Options bounds = new BitmapFactory.Options();
                bounds.inJustDecodeBounds = true;
                try (InputStream input = getContentResolver().openInputStream(entry.openUri())) {
                    BitmapFactory.decodeStream(input, null, bounds);
                }
                if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null;
                BitmapFactory.Options options = new BitmapFactory.Options();
                options.inPreferredConfig = Bitmap.Config.ARGB_8888;
                options.inSampleSize = 1;
                while (bounds.outWidth / options.inSampleSize > width
                        || bounds.outHeight / options.inSampleSize > height) {
                    options.inSampleSize *= 2;
                }
                try (InputStream input = getContentResolver().openInputStream(entry.openUri())) {
                    return BitmapFactory.decodeStream(input, null, options);
                }
            } catch (Exception ignored) {
                return null;
            }
        }

        private void clearBitmap() {
            imageView.setImageDrawable(null);
            if (displayedBitmap != null) {
                displayedBitmap.recycle();
                displayedBitmap = null;
            }
        }
    }

    private void openApkPackage(FileEntry entry) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                && !getPackageManager().canRequestPackageInstalls()) {
            pendingPackageEntry = entry;
            new AlertDialog.Builder(this)
                    .setTitle(getString(R.string.apk_install_permission_title))
                    .setMessage(getString(R.string.apk_install_permission_message, entry.name()))
                    .setPositiveButton(getString(R.string.open_settings), (dialog, which) -> {
                        try {
                            Intent settingsIntent = new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:" + getPackageName()));
                            startActivity(settingsIntent);
                        } catch (Exception exception) {
                            pendingPackageEntry = null;
                            Toast.makeText(this, getString(R.string.apk_installer_unavailable),
                                    Toast.LENGTH_SHORT).show();
                        }
                    })
                    .setNegativeButton(getString(R.string.cancel), (dialog, which) -> pendingPackageEntry = null)
                    .show();
            return;
        }
        launchPackageInstaller(entry);
    }

    private void launchPackageInstaller(FileEntry entry) {
        try {
            Uri uri = entry.openUri();
            Intent intent = new Intent(Intent.ACTION_VIEW);
            intent.setDataAndType(uri, "application/vnd.android.package-archive");
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            if (intent.resolveActivity(getPackageManager()) == null) {
                throw new IllegalStateException("No package installer available");
            }
            startActivity(intent);
            updateGlobalStatus(getString(R.string.apk_installer_opened, entry.name()));
        } catch (Exception exception) {
            pendingPackageEntry = null;
            Toast.makeText(this, getString(R.string.apk_installer_unavailable), Toast.LENGTH_SHORT).show();
        }
    }

    private String mimeTypeForName(String name) {
        if (name != null && name.toLowerCase(Locale.ROOT).endsWith(".apk")) {
            return "application/vnd.android.package-archive";
        }
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

    private boolean hasUsableStorageAccess() {
        if (Build.VERSION.SDK_INT == Build.VERSION_CODES.Q) {
            String saved = getPreferences(MODE_PRIVATE).getString(PREF_DOCUMENT_TREE, "");
            return saved != null && !saved.isEmpty() && documentEntryFromTree(Uri.parse(saved)) != null;
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return Environment.isExternalStorageManager();
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true;
        }
        boolean canRead = checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE)
                == PackageManager.PERMISSION_GRANTED;
        boolean canWrite = Build.VERSION.SDK_INT > Build.VERSION_CODES.P
                || checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED;
        return canRead && canWrite;
    }

    private String storageStatusMessage() {
        if (!hasUsableStorageAccess()) {
            return getString(R.string.storage_access_required_status);
        }
        if (Build.VERSION.SDK_INT == Build.VERSION_CODES.Q) {
            return getString(R.string.storage_android10_status);
        }
        return getString(R.string.ready);
    }

    private void requestStorageAccess() {
        if (Build.VERSION.SDK_INT == Build.VERSION_CODES.Q) {
            Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION
                    | Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                    | Intent.FLAG_GRANT_PREFIX_URI_PERMISSION);
            startActivityForResult(intent, REQUEST_DOCUMENT_TREE);
            return;
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            openAllFilesSettings();
            return;
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return;
        }
        if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.P) {
            requestPermissions(new String[]{
                    Manifest.permission.READ_EXTERNAL_STORAGE,
                    Manifest.permission.WRITE_EXTERNAL_STORAGE
            }, REQUEST_STORAGE);
        } else {
            requestPermissions(new String[]{Manifest.permission.READ_EXTERNAL_STORAGE}, REQUEST_STORAGE);
        }
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode != REQUEST_STORAGE || leftPane == null || rightPane == null) {
            return;
        }
        leftPane.reloadTreeKeepingExpansion();
        rightPane.reloadTreeKeepingExpansion();
        buildLayout();
        refreshEverything(storageStatusMessage());
        if (hasUsableStorageAccess()) {
            maybeShowFirstRunHelp();
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != REQUEST_DOCUMENT_TREE || resultCode != RESULT_OK || data == null || data.getData() == null) {
            return;
        }
        Uri treeUri = data.getData();
        try {
            if ((data.getFlags() & Intent.FLAG_GRANT_WRITE_URI_PERMISSION) != 0) {
                getContentResolver().takePersistableUriPermission(treeUri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
            } else {
                getContentResolver().takePersistableUriPermission(treeUri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION);
            }
        } catch (SecurityException exception) {
            updateGlobalStatus(getString(R.string.storage_tree_failed));
            return;
        }
        FileEntry root = documentEntryFromTree(treeUri);
        if (root == null) {
            updateGlobalStatus(getString(R.string.storage_tree_failed));
            return;
        }
        getPreferences(MODE_PRIVATE).edit().putString(PREF_DOCUMENT_TREE, treeUri.toString()).apply();
        leftPane.setRoot(root);
        FileEntry secondRoot = documentEntryFromTree(treeUri);
        rightPane.setRoot(secondRoot == null ? root : secondRoot);
        buildLayout();
        refreshEverything(getString(R.string.storage_tree_ready));
        maybeShowFirstRunHelp();
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
        operationInProgress = true;
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
        operationInProgress = false;
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

    private boolean isEntryInside(FileEntry parent, FileEntry child) {
        if (parent == null || child == null) {
            return false;
        }
        FileEntry cursor = child;
        while (cursor != null) {
            if (parent.key().equals(cursor.key())) {
                return true;
            }
            cursor = cursor.parent;
        }
        if (parent.documentUri != null && child.documentUri != null) {
            try {
                String parentId = DocumentsContract.getDocumentId(parent.documentUri);
                String childId = DocumentsContract.getDocumentId(child.documentUri);
                return childId.equals(parentId) || childId.startsWith(parentId + "/");
            } catch (IllegalArgumentException ignored) {
                return false;
            }
        }
        if (parent.file != null && child.file != null) {
            return isInside(parent.file, child.file);
        }
        return false;
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
        GestureDetector fileTapGestures;
        boolean fileDoubleTapConsumed = false;
        long currentDirectoryBytes = -1L;
        int statsGeneration = 0;

        CommanderPane(String title, FileEntry root, String accent) {
            this.title = title;
            this.accent = accent;
            setRoot(root);
        }

        void setRoot(FileEntry root) {
            currentDirectory = root;
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
            if (currentDirectory.isDocument() || isTelevision()) {
                pathText.setFocusable(false);
                pathText.setCursorVisible(false);
            }
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
            fileTapGestures = new GestureDetector(MainActivity.this,
                    new GestureDetector.SimpleOnGestureListener() {
                        @Override
                        public boolean onDown(MotionEvent event) {
                            return true;
                        }

                        @Override
                        public boolean onDoubleTap(MotionEvent event) {
                            int position = fileList.pointToPosition((int) event.getX(), (int) event.getY());
                            if (position < 0 || position >= visibleEntries.size()) return false;
                            fileDoubleTapConsumed = true;
                            lastClickedPosition = -1;
                            lastClickAt = 0L;
                            FileEntry entry = visibleEntries.get(position);
                            if (entry.isDirectoryLike()) {
                                openDirectory(entry);
                            } else {
                                openExternal(entry);
                            }
                            return true;
                        }
                    });
            fileList.setOnItemClickListener((parent, view, position, id) -> handleFileTap(position));
            fileList.setOnItemLongClickListener((parent, view, position, id) -> startFileDrag(position, view));
            fileList.setOnTouchListener((view, event) -> handleFileTouch(event));
            fileList.setOnDragListener((view, event) -> handleFileListDrop(event));
            fileColumn.addView(fileList, new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    0,
                    1f));

            TextView emptyFiles = new TextView(MainActivity.this);
            emptyFiles.setText(hasUsableStorageAccess()
                    ? getString(R.string.folder_empty)
                    : getString(R.string.storage_empty));
            emptyFiles.setTextColor(color(theme.secondaryText));
            emptyFiles.setTextSize(13);
            emptyFiles.setGravity(Gravity.CENTER);
            emptyFiles.setPadding(dp(16), dp(16), dp(16), dp(16));
            fileColumn.addView(emptyFiles, new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    0,
                    1f));
            fileList.setEmptyView(emptyFiles);

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
            fileDoubleTapConsumed = false;
            if (fileTapGestures != null) {
                fileTapGestures.onTouchEvent(event);
                if (fileDoubleTapConsumed) return true;
            }
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
            lastClickedPosition = -1;
            lastClickAt = 0L;
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
            setRoot(new FileEntry(target, null));
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

        private void rebaseAfterRename(File source, File destination) {
            currentDirectory = rebaseEntryAfterRename(currentDirectory, source, destination);
            FileEntry rootEntry = rebaseEntryAfterRename(rootNode.entry, source, destination);
            if (rootEntry != rootNode.entry) {
                rootNode = new TreeNode(rootEntry, 0);
                rootNode.expanded = true;
                loadChildren(rootNode);
            }
        }

        private void ensureDocumentDirectoryReadable() {
            if (!currentDirectory.isDocument()) {
                return;
            }
            FileEntry refreshed = queryDocumentEntry(currentDirectory.documentUri, currentDirectory.parent);
            if (refreshed != null) {
                currentDirectory = refreshed;
                return;
            }
            currentDirectory = rootNode.entry;
        }

        private FileEntry rebaseEntryAfterRename(FileEntry entry, File source, File destination) {
            if (entry.file == null) {
                return entry;
            }
            if (!isInside(source, entry.file)) {
                return entry;
            }
            String sourcePath;
            String entryPath;
            try {
                sourcePath = source.getCanonicalPath();
                entryPath = entry.file.getCanonicalPath();
            } catch (IOException exception) {
                sourcePath = source.getAbsolutePath();
                entryPath = entry.file.getAbsolutePath();
            }
            File rebasedFile = destination;
            if (!entryPath.equals(sourcePath)) {
                String relative = entryPath.substring(sourcePath.length() + 1);
                rebasedFile = new File(destination, relative);
            }
            if (entry.zipPath != null) {
                return new FileEntry(rebasedFile, null, entry.zipPath, entry.zipDirectory, entry.zipSize, entry.zipModified);
            }
            return new FileEntry(rebasedFile, null);
        }

        private TreeNode rebuildNode(FileEntry entry, int depth, Set<String> expanded) {
            TreeNode node = new TreeNode(entry, depth);
            node.expanded = depth == 0 || expanded.contains(entry.key()) || isEntryInside(entry, currentDirectory);
            loadChildren(node);
            return node;
        }

        private boolean ensureTreePathVisible(TreeNode node, FileEntry target) {
            if (node.entry.key().equals(target.key())) {
                node.expanded = true;
                return true;
            }
            if (!isEntryInside(node.entry, target)) {
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
        final Uri documentUri;
        final String documentName;
        final String documentMime;
        final int documentFlags;
        final long documentSize;
        final long documentModified;
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
            this.documentUri = null;
            this.documentName = null;
            this.documentMime = null;
            this.documentFlags = 0;
            this.documentSize = 0L;
            this.documentModified = 0L;
            this.parent = parent;
            this.zipPath = zipPath;
            this.zipDirectory = zipDirectory;
            this.zipSize = zipSize;
            this.zipModified = zipModified;
        }

        FileEntry(Uri documentUri, FileEntry parent, String name, String mime,
                  long size, long modified, int flags) {
            this.file = null;
            this.documentUri = documentUri;
            this.documentName = name == null || name.isEmpty() ? getString(R.string.document_root) : name;
            this.documentMime = mime == null ? "application/octet-stream" : mime;
            this.documentFlags = flags;
            this.documentSize = Math.max(0L, size);
            this.documentModified = Math.max(0L, modified);
            this.parent = parent;
            this.zipPath = null;
            this.zipDirectory = false;
            this.zipSize = 0L;
            this.zipModified = 0L;
        }

        FileEntry(File archiveFile, Uri documentUri, FileEntry parent, String name, String mime,
                  long size, long modified, int flags, String zipPath,
                  boolean zipDirectory, long zipSize, long zipModified) {
            this.file = archiveFile;
            this.documentUri = documentUri;
            this.documentName = name;
            this.documentMime = mime;
            this.documentFlags = flags;
            this.documentSize = size;
            this.documentModified = modified;
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
            if (documentUri != null) {
                return documentUri.toString();
            }
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
            if (documentUri != null) {
                return documentName;
            }
            String name = file.getName();
            return name.isEmpty() ? file.getAbsolutePath() : name;
        }

        String mimeType() {
            if (isDirectoryLike()) {
                return "resource/folder";
            }
            if (zipPath != null) {
                return mimeTypeForName(name());
            }
            return documentUri != null ? documentMime : mimeTypeForName(name());
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
            if (documentUri != null) {
                return documentUri;
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
            return zipPath == null && (documentUri != null
                    ? DocumentsContract.Document.MIME_TYPE_DIR.equals(documentMime)
                    : file.isDirectory());
        }

        boolean isZipArchive() {
            return zipPath == null && !isPhysicalDirectory() && name().toLowerCase(Locale.ROOT).endsWith(".zip");
        }

        boolean isApkPackage() {
            return zipPath == null && !isPhysicalDirectory()
                    && ("application/vnd.android.package-archive".equals(documentMime)
                    || name().toLowerCase(Locale.ROOT).endsWith(".apk"));
        }

        boolean isZipEntry() {
            return zipPath != null;
        }

        boolean isDirectoryLike() {
            return isPhysicalDirectory() || isZipArchive() || (zipPath != null && zipDirectory);
        }

        boolean isDocument() {
            return documentUri != null;
        }

        boolean canWriteDirectory() {
            if (!isPhysicalDirectory()) {
                return false;
            }
            if (documentUri == null) {
                return file.canWrite();
            }
            return (documentFlags & DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE) != 0;
        }

        String displayPath() {
            if (zipPath != null) {
                return (documentUri != null ? documentName : file.getAbsolutePath()) + "!/" + zipPath;
            }
            if (isZipArchive()) {
                return (documentUri != null ? documentName : file.getAbsolutePath()) + "!/";
            }
            if (documentUri != null) {
                List<String> names = new ArrayList<>();
                FileEntry current = this;
                while (current != null && current.documentUri != null) {
                    names.add(current.name());
                    current = current.parent;
                }
                Collections.reverse(names);
                return String.join(" / ", names);
            }
            return file.getAbsolutePath();
        }

        long size() {
            return zipPath != null ? zipSize : (documentUri != null ? documentSize : file.length());
        }

        long modified() {
            return zipPath != null ? zipModified : (documentUri != null ? documentModified : file.lastModified());
        }

        long contentBytes() {
            if (isZipArchive() || isZipEntry()) {
                return zipContentBytes();
            }
            if (documentUri != null) {
                if (!isPhysicalDirectory()) {
                    return Math.max(1L, documentSize);
                }
                long total = 0L;
                for (FileEntry child : children(false)) {
                    total += child.contentBytes();
                }
                return Math.max(1L, total);
            }
            return totalBytes(file);
        }

        List<FileEntry> children(boolean directoriesOnly) {
            if (isZipArchive() || isZipEntry()) {
                return zipChildren(directoriesOnly);
            }
            if (documentUri != null) {
                return documentChildren(directoriesOnly);
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

        private List<FileEntry> documentChildren(boolean directoriesOnly) {
            if (!isPhysicalDirectory()) {
                return Collections.emptyList();
            }
            List<FileEntry> entries = new ArrayList<>();
            String[] projection = {
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                    DocumentsContract.Document.COLUMN_SIZE,
                    DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                    DocumentsContract.Document.COLUMN_FLAGS
            };
            try {
                String documentId = DocumentsContract.getDocumentId(documentUri);
                Uri childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(documentUri, documentId);
                try (Cursor cursor = getContentResolver().query(childrenUri, projection, null, null, null)) {
                    if (cursor == null) {
                        return Collections.emptyList();
                    }
                    while (cursor.moveToNext()) {
                        String childId = cursor.getString(0);
                        String name = cursor.getString(1);
                        String mime = cursor.getString(2);
                        long size = cursor.isNull(3) ? 0L : cursor.getLong(3);
                        long modified = cursor.isNull(4) ? 0L : cursor.getLong(4);
                        int flags = cursor.isNull(5) ? 0 : cursor.getInt(5);
                        boolean directory = DocumentsContract.Document.MIME_TYPE_DIR.equals(mime);
                        if (directoriesOnly && !directory && (name == null || !name.toLowerCase(Locale.ROOT).endsWith(".zip"))) {
                            continue;
                        }
                        Uri childUri = DocumentsContract.buildDocumentUriUsingTree(documentUri, childId);
                        entries.add(new FileEntry(childUri, this, name, mime, size, modified, flags));
                    }
                }
            } catch (Exception ignored) {
                return Collections.emptyList();
            }
            Collections.sort(entries, entryComparator());
            return entries;
        }

        private FileEntry findChild(String childName) {
            if (childName == null) {
                return null;
            }
            for (FileEntry child : children(false)) {
                if (childName.equalsIgnoreCase(child.name())) {
                    return child;
                }
            }
            return null;
        }

        private List<FileEntry> zipChildren(boolean directoriesOnly) {
            List<FileEntry> entries = new ArrayList<>();
            String prefix = zipPath == null ? "" : zipPath;
            if (!prefix.isEmpty() && !prefix.endsWith("/")) {
                prefix += "/";
            }
            Set<String> seen = new HashSet<>();
            try {
                File archive = archiveFile();
                try (ZipFile zip = new ZipFile(archive)) {
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
                    if (documentUri != null) {
                        entries.add(new FileEntry(archive, documentUri, this, documentName, documentMime,
                                documentSize, documentModified, documentFlags, childPath, directory,
                                zipEntry.getSize(), zipEntry.getTime()));
                    } else {
                        entries.add(new FileEntry(archive, this, childPath, directory,
                                zipEntry.getSize(), zipEntry.getTime()));
                    }
                }
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
            try (ZipFile zip = new ZipFile(archiveFile())) {
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
            try (ZipFile zip = new ZipFile(archiveFile())) {
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

        private synchronized File archiveFile() throws IOException {
            if (file != null) {
                return file;
            }
            if (documentUri == null) {
                throw new IOException(getString(R.string.no_readable_selection));
            }
            String cacheName = "saf_zip_" + Integer.toHexString(documentUri.toString().hashCode())
                    + "_" + documentModified + "_" + documentSize + ".zip";
            File cached = new File(getCacheDir(), cacheName);
            if (cached.isFile() && documentModified > 0L) {
                return cached;
            }
            try (InputStream input = getContentResolver().openInputStream(documentUri);
                 OutputStream output = new FileOutputStream(cached)) {
                if (input == null) {
                    throw new IOException(getString(R.string.no_readable_selection));
                }
                byte[] buffer = new byte[1024 * 64];
                int read;
                while ((read = input.read(buffer)) != -1) {
                    output.write(buffer, 0, read);
                }
            } catch (IOException | SecurityException exception) {
                if (cached.exists()) {
                    cached.delete();
                }
                if (exception instanceof IOException) {
                    throw (IOException) exception;
                }
                throw new IOException(getString(R.string.no_readable_selection), exception);
            }
            return cached;
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
                total += entry.contentBytes();
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

    private final class LastOperation {
        final boolean move;
        final boolean zip;
        final boolean delete;
        final boolean trash;
        final File backupRoot;
        final List<OperationRecord> records = new ArrayList<>();
        final List<StorageOperationRecord> storageRecords = new ArrayList<>();
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
                return activity.getString(R.string.zip_label, recordCount());
            }
            if (delete) {
                return activity.getString(R.string.delete_label, recordCount());
            }
            if (trash) {
                return activity.getString(R.string.trash_label, recordCount());
            }
            return activity.getString(move ? R.string.move_label : R.string.copy_label, recordCount());
        }

        int recordCount() {
            return records.size() + storageRecords.size();
        }
    }

    private enum ConflictMode {
        KEEP,
        REPLACE
    }

    private final class OperationRecord {
        final File original;
        final File destination;
        final File replacedBackup;
        final byte[] destinationSnapshot;
        boolean destinationReverted;

        OperationRecord(File original, File destination, File replacedBackup) {
            this.original = original;
            this.destination = destination;
            this.replacedBackup = replacedBackup;
            this.destinationSnapshot = captureSnapshot(new FileEntry(destination, null));
        }
    }

    private final class StorageOperationRecord {
        final FileEntry originalParent;
        final String originalName;
        final FileEntry targetParent;
        final String destinationName;
        final FileEntry destination;
        final File sourceBackup;
        final File replacedBackup;
        final byte[] destinationSnapshot;
        boolean destinationReverted;
        boolean sourceRestored;

        StorageOperationRecord(FileEntry originalParent, String originalName,
                               FileEntry targetParent, String destinationName,
                               FileEntry destination, File sourceBackup, File replacedBackup) {
            this.originalParent = originalParent;
            this.originalName = originalName;
            this.targetParent = targetParent;
            this.destinationName = destinationName;
            this.destination = destination;
            this.sourceBackup = sourceBackup;
            this.replacedBackup = replacedBackup;
            this.destinationSnapshot = destination == null ? null : captureSnapshot(destination);
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
