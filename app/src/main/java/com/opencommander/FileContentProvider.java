package com.opencommander;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;

import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.net.URLConnection;

public class FileContentProvider extends ContentProvider {
    public static final String AUTHORITY = "com.opencommander.files";

    @Override
    public boolean onCreate() {
        return true;
    }

    @Override
    public String getType(Uri uri) {
        try {
            String type = URLConnection.guessContentTypeFromName(safeFileFromUri(uri).getName());
            return type == null ? "application/octet-stream" : type;
        } catch (FileNotFoundException exception) {
            return "application/octet-stream";
        }
    }

    @Override
    public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (!"r".equals(mode)) {
            throw new FileNotFoundException("Only read access is supported.");
        }
        File file = safeFileFromUri(uri);
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY);
    }

    @Override
    public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) {
        String[] columns = projection == null
                ? new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE}
                : projection;
        File file;
        try {
            file = safeFileFromUri(uri);
        } catch (FileNotFoundException exception) {
            return new MatrixCursor(columns, 0);
        }
        MatrixCursor cursor = new MatrixCursor(columns, 1);
        MatrixCursor.RowBuilder row = cursor.newRow();
        for (String column : columns) {
            if (OpenableColumns.DISPLAY_NAME.equals(column)) {
                row.add(file.getName());
            } else if (OpenableColumns.SIZE.equals(column)) {
                row.add(file.length());
            } else {
                row.add(null);
            }
        }
        return cursor;
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        throw new UnsupportedOperationException("Insert is not supported.");
    }

    @Override
    public int delete(Uri uri, String selection, String[] selectionArgs) {
        throw new UnsupportedOperationException("Delete is not supported.");
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) {
        throw new UnsupportedOperationException("Update is not supported.");
    }

    private File safeFileFromUri(Uri uri) throws FileNotFoundException {
        String path = uri.getPath();
        if (path == null || path.trim().isEmpty()) {
            throw new FileNotFoundException("Missing file path.");
        }
        try {
            File file = new File(path).getCanonicalFile();
            if (!file.isFile() || !file.canRead()) {
                throw new FileNotFoundException("File is not readable.");
            }
            return file;
        } catch (IOException exception) {
            throw new FileNotFoundException("Invalid file path.");
        }
    }
}
