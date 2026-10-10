import 'corpus_library.dart';
import 'isolate_runner.dart';

void corpusLibraryWorkerEntry(IsolateWorkerBoot boot) {
  isolateWorkerRun(boot, (ctx) async {
    final args = boot.args! as Map<String, Object?>;
    final library = CorpusLibrary(args['directory']! as String);
    ctx.checkCancelled();
    switch (args['operation']) {
      case 'inventory':
        return library.inventory().toMap();
      case 'content':
        return library.content(
          args['id']! as String,
          offset: args['offset'] as int? ?? 0,
          limit: args['limit'] as int? ?? 40,
          query: args['query'] as String? ?? '',
        );
      case 'delete':
        return await library.deleteDocument(
          args['id']! as String,
          args['revision']! as String,
        );
      case 'recover':
        library.recoverPendingDelete();
        return <String, Object?>{'ok': true};
      default:
        throw const FormatException('未知资料管理操作');
    }
  });
}
