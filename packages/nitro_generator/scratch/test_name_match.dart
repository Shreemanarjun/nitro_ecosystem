void main() {
  String typeName = "PackageBoxes";
  List<String> recordTypes = ["PackageBoxes", "LiveTrackingUpdate"];
  print("isRecordItem: ${recordTypes.contains(typeName)}");

  String nullableTypeName = "PackageBoxes?";
  print("isRecordItem (nullable): ${recordTypes.contains(nullableTypeName.replaceAll('?', ''))}");
}
