/// La lista de pistas conserva el orden elegido en el servidor.
class BookTrack {
  const BookTrack(this.id, this.title);
  final String id, title;

  factory BookTrack.fromJson(Map<String, dynamic> json) =>
      BookTrack(json['id'] as String, json['title'] as String);
  Map<String, dynamic> toJson() => {'id': id, 'title': title};
}

class AudioBook {
  const AudioBook({
    required this.id,
    required this.title,
    required this.tracks,
    this.author = '',
    this.narrator = '',
    this.description = '',
    this.poster,
    this.backdrop,
    this.revision = 1,
  });

  final String id, title, author, narrator, description;
  final String? poster, backdrop;
  final int revision;
  final List<BookTrack> tracks;

  factory AudioBook.fromJson(Map<String, dynamic> json) => AudioBook(
    id: json['id'] as String,
    title: json['title'] as String,
    author: json['author'] as String? ?? '',
    narrator: json['narrator'] as String? ?? '',
    description: json['description'] as String? ?? '',
    poster: json['poster'] as String?,
    backdrop: json['backdrop'] as String?,
    revision: json['revision'] as int? ?? 1,
    tracks: [
      for (final t in json['tracks'] as List)
        BookTrack.fromJson(t as Map<String, dynamic>),
    ],
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'narrator': narrator,
    'description': description,
    'revision': revision,
    'poster': poster,
    'backdrop': backdrop,
    'tracks': [for (final track in tracks) track.toJson()],
  };
}
