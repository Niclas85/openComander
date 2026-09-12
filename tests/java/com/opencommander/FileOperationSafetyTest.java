package com.opencommander;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.attribute.FileTime;
import java.util.ArrayList;
import java.util.List;

public final class FileOperationSafetyTest {
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    private static FileOperationSafety.Node node(Path path) {
        return new FileOperationSafety.Node() {
            public String name() { return path.getFileName().toString(); }
            public String identity() throws IOException { return Files.getLastModifiedTime(path).toString(); }
            public boolean directory() { return Files.isDirectory(path); }
            public List<FileOperationSafety.Node> children() throws IOException {
                List<FileOperationSafety.Node> result = new ArrayList<>();
                try (var stream = Files.list(path)) { stream.forEach(p -> result.add(node(p))); }
                return result;
            }
            public InputStream open() throws IOException { return Files.newInputStream(path); }
        };
    }

    public static void main(String[] args) throws Exception {
        Path fixture = Files.createTempDirectory("opencommander-safety-test-");
        try {
            Path source = Files.createDirectory(fixture.resolve("source"));
            Path a = Files.writeString(source.resolve("a.txt"), "first");
            Path b = Files.writeString(source.resolve("b.txt"), "second");
            Path destination = fixture.resolve("destination");
            try {
                FileOperationSafety.copyThenDelete(() -> {
                    Files.createDirectory(destination);
                    Files.copy(a, destination.resolve("a.txt"));
                    Files.copy(b, destination.resolve("b.txt"));
                }, () -> {
                    Files.delete(a);
                    throw new IOException("Injected failure after deleting one source child");
                });
                throw new AssertionError("Expected cleanup failure");
            } catch (FileOperationSafety.SourceCleanupException expected) {
                check(Files.readString(destination.resolve("a.txt")).equals("first"), "First file retained");
                check(Files.readString(destination.resolve("b.txt")).equals("second"), "Second file retained");
                check(Files.exists(b), "Remaining source retained");
            }
            Path crossSource = Files.createDirectory(fixture.resolve("cross-source"));
            Files.writeString(crossSource.resolve("a"), "one");
            Files.writeString(crossSource.resolve("b"), "two");
            Path crossTarget = fixture.resolve("cross-target");
            try {
                FileOperationSafety.moveToNewPath(crossSource.toFile(), crossTarget.toFile(), (from, to) -> {
                    Files.createDirectory(to.toPath());
                    Files.copy(from.toPath().resolve("a"), to.toPath().resolve("a"));
                    Files.copy(from.toPath().resolve("b"), to.toPath().resolve("b"));
                }, from -> {
                    Files.delete(from.toPath().resolve("a"));
                    throw new IOException("Injected partial source deletion");
                }, (from, to) -> { throw new IOException("Injected cross-volume rename failure"); });
                throw new AssertionError("Expected cross-volume cleanup failure");
            } catch (FileOperationSafety.SourceCleanupException expected) {
                check(Files.readString(crossTarget.resolve("a")).equals("one"), "Published cross-volume copy retained");
                check(Files.readString(crossTarget.resolve("b")).equals("two"), "Published tree remains complete");
            }
            Path occupied = Files.writeString(fixture.resolve("occupied"), "do not overwrite");
            try {
                FileOperationSafety.copyToNewPath(b.toFile(), occupied.toFile(),
                        (from, to) -> Files.copy(from.toPath(), to.toPath()));
                throw new AssertionError("Expected destination conflict");
            } catch (java.nio.file.FileAlreadyExistsException expected) {
                check(Files.readString(occupied).equals("do not overwrite"), "Existing target retained");
            }
            Path failedTarget = fixture.resolve("failed-target");
            try {
                FileOperationSafety.copyToNewPath(b.toFile(), failedTarget.toFile(), (from, to) -> {
                    Files.writeString(to.toPath(), "partial");
                    throw new IOException("Injected copy failure");
                });
                throw new AssertionError("Expected staged copy failure");
            } catch (IOException expected) {
                check(!Files.exists(failedTarget), "Partial copy never published");
                check(Files.exists(b), "Source retained after staged failure");
            }
            Path racedTarget = fixture.resolve("raced-target");
            try {
                FileOperationSafety.copyToNewPath(b.toFile(), racedTarget.toFile(), (from, to) -> {
                    Files.copy(from.toPath(), to.toPath());
                    Files.writeString(racedTarget, "created by another writer");
                });
                throw new AssertionError("Expected publication conflict");
            } catch (java.nio.file.FileAlreadyExistsException expected) {
                check(Files.readString(racedTarget).equals("created by another writer"), "Racing writer retained");
            }
            boolean[] deleted = {false};
            try {
                FileOperationSafety.copyThenDelete(() -> { throw new IOException("Injected copy failure"); },
                        () -> deleted[0] = true);
                throw new AssertionError("Expected copy failure");
            } catch (FileOperationSafety.SourceCleanupException wrong) {
                throw new AssertionError("Copy failure misclassified", wrong);
            } catch (IOException expected) {
                check(!deleted[0], "No source deletion after copy failure");
            }
            Path file = destination.resolve("a.txt");
            byte[] snapshot = FileOperationSafety.snapshot(node(destination));
            check(FileOperationSafety.unchanged(snapshot, node(destination)), "Unmodified tree accepted");
            FileTime timestamp = Files.getLastModifiedTime(file);
            Files.writeString(file, "other"); // Same byte count, restore timestamp: metadata alone is insufficient.
            Files.setLastModifiedTime(file, timestamp);
            check(!FileOperationSafety.unchanged(snapshot, node(destination)), "Same-size edit detected by content");
            snapshot = FileOperationSafety.snapshot(node(destination));
            Files.writeString(destination.resolve("added.txt"), "new child");
            check(!FileOperationSafety.unchanged(snapshot, node(destination)), "Added child detected");
            check(!FileOperationSafety.unchanged(null, node(destination)), "Missing snapshot fails closed");
            try {
                FileOperationSafety.unchanged(snapshot, node(fixture.resolve("missing")));
                throw new AssertionError("Unreadable tree accepted");
            } catch (IOException expected) { }
            System.out.println("PASS: staged publication, cross-volume partial deletion, existing/racing targets, copy failure, unchanged tree, same-size edits, added children, missing snapshots and unreadable files");
        } finally {
            try (var paths = Files.walk(fixture)) {
                for (Path path : paths.sorted(java.util.Comparator.reverseOrder()).toList()) Files.delete(path);
            }
        }
    }
}
