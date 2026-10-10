import 'package:sqlite3/sqlite3.dart';
import '../../review/rework_models.dart';

List<Map<String,Object?>> readReworkEvidence(Database? db,String subjectId,List<String> ids) {
  if(ids.length>12)throw const FormatException('最多选择 12 条证据');
  if(ids.isEmpty)return [];
  if(db==null)throw const FormatException('尚未建立语料库，请先导入或补充证据');
  final out=<Map<String,Object?>>[];
  for(final id in ids.toSet()) {
    final rows=db.select("SELECT * FROM chunks WHERE chunk_id=? AND subject_id=? AND source_type IN ('ppt','textbook')",[id,subjectId]);
    if(rows.isEmpty)throw FormatException('证据已失效或不属于该科课件/教材：$id');
    final row=rows.single;final text=row['text']?.toString()??'';
    if(text.trim().isEmpty)throw FormatException('证据没有正文：$id');
    final start=row['page_start']?.toString()??'?';final end=row['page_end']?.toString()??start;
    final evidence=<String,Object?>{'chunkId':id,'subjectId':subjectId,'deck':row['deck'],'title':row['title'],
      'sourceType':row['source_type'],'pageRange':start==end?start:'$start-$end','text':text};
    evidence['hash']=reworkEvidenceHash(evidence);out.add(evidence);
  }
  return out;
}
