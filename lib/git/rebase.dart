/// Pure model + file builders for interactive rebase.
///
/// Execution strategy (see RebaseOps): we run `git rebase -i <base>` with
/// GIT_SEQUENCE_EDITOR pointing at a helper that replaces git's generated
/// todo with [buildTodoFile]'s output, and GIT_EDITOR pointing at a helper
/// that consumes [buildEditorQueue]'s queue — one entry per editor
/// invocation, in todo order: reworded commits get their queued message,
/// squash messages are accepted as git combined them.
library;

enum RebaseAction { pick, reword, squash, fixup, drop }

class RebaseTodoEntry {
  final String hash;
  final String subject;
  final RebaseAction action;

  /// Full replacement message; required (non-empty) when [action] is reword.
  final String? newMessage;

  const RebaseTodoEntry({
    required this.hash,
    required this.subject,
    this.action = RebaseAction.pick,
    this.newMessage,
  });

  RebaseTodoEntry copyWith({RebaseAction? action, String? newMessage}) =>
      RebaseTodoEntry(
        hash: hash,
        subject: subject,
        action: action ?? this.action,
        newMessage: newMessage ?? this.newMessage,
      );

  String get shortHash => hash.length >= 7 ? hash.substring(0, 7) : hash;
}

class RebasePlan {
  /// The commit the todo entries replay onto (exclusive base).
  final String baseHash;

  /// Entries in final desired order, oldest (applied first) first.
  final List<RebaseTodoEntry> entries;

  const RebasePlan({required this.baseHash, required this.entries});
}

/// Returns a human-readable problem with [plan], or null when it is valid.
String? validatePlan(RebasePlan plan) {
  if (plan.entries.isEmpty) return 'Nothing to rebase.';
  final kept =
      plan.entries.where((e) => e.action != RebaseAction.drop).toList();
  if (kept.isEmpty) {
    return 'Every commit is dropped — that would discard all of them. '
        'Use reset instead if that is really the goal.';
  }
  final first = kept.first;
  if (first.action == RebaseAction.squash ||
      first.action == RebaseAction.fixup) {
    return 'The first kept commit cannot be a squash/fixup — '
        'there is no earlier commit to fold it into.';
  }
  for (final e in plan.entries) {
    if (e.action == RebaseAction.reword &&
        (e.newMessage == null || e.newMessage!.trim().isEmpty)) {
      return 'Reworded commit ${e.shortHash} has an empty message.';
    }
  }
  return null;
}

/// The todo file content handed to git (replaces its generated one).
String buildTodoFile(RebasePlan plan) {
  final buf = StringBuffer();
  for (final e in plan.entries) {
    // Subjects are informational to git; hashes are what executes.
    buf.writeln('${e.action.name} ${e.hash} ${e.subject}');
  }
  return buf.toString();
}

/// One queue line per expected GIT_EDITOR invocation, in todo order:
/// `MSG:<name>` → replace the message file with payload `<name>`;
/// `KEEP` → accept git's prepared content (squash combined message).
///
/// Git opens the editor for each `reword` and each `squash` (not for pick,
/// fixup or drop). Returns the queue lines and the payload files.
(List<String>, Map<String, String>) buildEditorQueue(RebasePlan plan) {
  final queue = <String>[];
  final payloads = <String, String>{};
  var n = 0;
  for (final e in plan.entries) {
    switch (e.action) {
      case RebaseAction.reword:
        n++;
        final name = 'msg$n';
        // Ensure a trailing newline; git is tolerant but tools expect it.
        var msg = e.newMessage ?? '';
        if (!msg.endsWith('\n')) msg = '$msg\n';
        payloads[name] = msg;
        queue.add('MSG:$name');
      case RebaseAction.squash:
        queue.add('KEEP');
      case RebaseAction.pick:
      case RebaseAction.fixup:
      case RebaseAction.drop:
        break; // no editor invocation
    }
  }
  return (queue, payloads);
}

/// POSIX shell for the GIT_SEQUENCE_EDITOR helper: replace git's todo.
String sequenceEditorScript(String ctrlDir) => '#!/bin/sh\n'
    'cp "$ctrlDir/todo" "\$1"\n';

/// POSIX shell for the GIT_EDITOR helper: consume the next queue entry.
/// The invocation counter lives in the control dir so a rebase paused on a
/// conflict keeps its place across `git rebase --continue` runs (each a new
/// git process).
String editorScript(String ctrlDir) => '#!/bin/sh\n'
    'n=\$(cat "$ctrlDir/n" 2>/dev/null || echo 0)\n'
    'n=\$((n+1))\n'
    'printf %s "\$n" > "$ctrlDir/n"\n'
    'line=\$(sed -n "\${n}p" "$ctrlDir/queue")\n'
    'case "\$line" in\n'
    '  MSG:*) cp "$ctrlDir/msgs/\${line#MSG:}" "\$1" ;;\n'
    '  *) : ;;\n'
    'esac\n'
    'exit 0\n';
