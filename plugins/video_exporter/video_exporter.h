#ifndef VIDEO_EXPORTER_H
#define VIDEO_EXPORTER_H

#include "core/object.h"
#include "core/ustring.h"

class VideoExporter : public Object {
	GDCLASS(VideoExporter, Object);

	static VideoExporter *singleton;

protected:
	static void _bind_methods();

public:
	static VideoExporter *get_singleton();

	VideoExporter();
	~VideoExporter();

	bool export_frames(
			const String &frames_directory,
			const String &output_path,
			int fps);
};

void godot_video_exporter_init();
void godot_video_exporter_deinit();

#endif // VIDEO_EXPORTER_H
