package com.opencommander;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.FileAlreadyExistsException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.SimpleFileVisitor;
import java.nio.file.FileVisitResult;
import java.nio.file.attribute.BasicFileAttributes;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;

/** Storage-independent checks; failures must never authorize destructive undo. */
final class FileOperationSafety {
    interface Node {
        String name();
        String identity() throws IOException;
        boolean directory() throws IOException;
        List<Node> children() throws IOException;
        InputStream open() throws IOException;
    }

    interface IOAction { void run() throws IOException; }
    interface CopyAction { void run(File source, File destination) throws IOException; }
    interface FileAction { void run(File file) throws IOException; }

    static void copyToNewPath(File source, File destination, CopyAction copy) throws IOException {
        requireVacant(destination);
        Path staging = Files.createTempDirectory(destination.getParentFile().toPath(), ".OpenCommanderTransfer-");
        File payload = staging.resolve("payload").toFile();
        try {
            copy.run(source, payload);
            Files.move(payload.toPath(), destination.toPath());
        } finally {
            // This directory was created by this call, never supplied by the caller.
            // walkFileTree does not follow symlinks.
            try {
                Files.walkFileTree(staging, new SimpleFileVisitor<Path>() {
                    @Override public FileVisitResult visitFile(Path file, BasicFileAttributes attributes) throws IOException {
                        Files.delete(file);
                        return FileVisitResult.CONTINUE;
                    }
                    @Override public FileVisitResult postVisitDirectory(Path directory, IOException error) throws IOException {
                        if (error != null) throw error;
                        Files.delete(directory);
                        return FileVisitResult.CONTINUE;
                    }
                });
            } catch (IOException ignored) {
                // A leftover private staging directory must not invalidate a completed move.
            }
        }
    }

    static void moveToNewPath(File source, File destination, CopyAction copy, FileAction delete) throws IOException {
        moveToNewPath(source, destination, copy, delete,
                (from, to) -> Files.move(from.toPath(), to.toPath()));
    }

    // The rename seam lets tests force the cross-volume path without touching a real disk.
    static void moveToNewPath(File source, File destination, CopyAction copy, FileAction delete,
                              CopyAction rename) throws IOException {
        requireVacant(destination);
        try {
            rename.run(source, destination);
        } catch (FileAlreadyExistsException conflict) {
            throw conflict;
        } catch (IOException cannotRename) {
            copyThenDelete(() -> copyToNewPath(source, destination, copy), () -> delete.run(source));
        }
    }

    private static void requireVacant(File destination) throws IOException {
        if (Files.exists(destination.toPath(), LinkOption.NOFOLLOW_LINKS)) {
            throw new FileAlreadyExistsException(destination.getAbsolutePath());
        }
    }

    static final class SourceCleanupException extends IOException {
        SourceCleanupException(IOException cause) { super(cause); }
    }

    static void copyThenDelete(IOAction copy, IOAction delete) throws IOException {
        copy.run();
        try {
            delete.run();
        } catch (IOException error) {
            // The destination is now the only complete copy. The caller MUST retain it.
            throw new SourceCleanupException(error);
        }
    }

    static byte[] snapshot(Node node) throws IOException {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            append(node, digest);
            return digest.digest();
        } catch (NoSuchAlgorithmException impossible) {
            throw new AssertionError(impossible);
        }
    }

    static boolean unchanged(byte[] expected, Node node) throws IOException {
        return expected != null && Arrays.equals(expected, snapshot(node));
    }

    private static void field(MessageDigest digest, String value) {
        byte[] data = value.getBytes(StandardCharsets.UTF_8);
        digest.update(Integer.toString(data.length).getBytes(StandardCharsets.US_ASCII));
        digest.update((byte) ':');
        digest.update(data);
    }

    private static void append(Node node, MessageDigest digest) throws IOException {
        field(digest, node.name());
        field(digest, node.identity());
        if (node.directory()) {
            digest.update((byte) 'D');
            List<Node> children = new ArrayList<>(node.children());
            children.sort(Comparator.comparing(Node::name));
            field(digest, Integer.toString(children.size()));
            for (Node child : children) append(child, digest);
        } else {
            digest.update((byte) 'F');
            // A separate content digest keeps tree boundaries unambiguous.
            try {
                MessageDigest content = MessageDigest.getInstance("SHA-256");
                try (InputStream input = node.open()) {
                    if (input == null) throw new IOException("File is not readable");
                    byte[] buffer = new byte[64 * 1024];
                    int count;
                    while ((count = input.read(buffer)) != -1) content.update(buffer, 0, count);
                }
                digest.update(content.digest());
            } catch (NoSuchAlgorithmException impossible) {
                throw new AssertionError(impossible);
            }
        }
    }
}
