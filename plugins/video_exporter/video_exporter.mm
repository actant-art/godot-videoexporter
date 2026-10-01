/*************************************************************************/
/* video_exporter.mm                                                     */
/*************************************************************************/

#include "video_exporter.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

VideoExporter::VideoExporter() {
}

VideoExporter::~VideoExporter() {
}

void VideoExporter::_bind_methods() {
	ClassDB::bind_method(
			D_METHOD(
					"export_frames",
					"frames_directory",
					"output_path",
					"fps"),
			&VideoExporter::export_frames);
}

static CVPixelBufferRef create_pixel_buffer_from_image(
		CGImageRef image,
		size_t width,
		size_t height) {

	CVPixelBufferRef pixel_buffer = nullptr;

	NSDictionary *attributes = @{
		(id)kCVPixelBufferCGImageCompatibilityKey : @YES,
		(id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES
	};

	CVReturn result = CVPixelBufferCreate(
			kCFAllocatorDefault,
			width,
			height,
			kCVPixelFormatType_32BGRA,
			(__bridge CFDictionaryRef)attributes,
			&pixel_buffer);

	if (result != kCVReturnSuccess || pixel_buffer == nullptr) {
		return nullptr;
	}

	CVPixelBufferLockBaseAddress(
			pixel_buffer,
			kCVPixelBufferLock_ReadOnly);

	void *base_address = CVPixelBufferGetBaseAddress(pixel_buffer);
	size_t bytes_per_row = CVPixelBufferGetBytesPerRow(pixel_buffer);

	CGColorSpaceRef color_space =
			CGColorSpaceCreateDeviceRGB();

	CGContextRef context = CGBitmapContextCreate(
			base_address,
			width,
			height,
			8,
			bytes_per_row,
			color_space,
			kCGBitmapByteOrder32Little |
					kCGImageAlphaPremultipliedFirst);

	if (context == nullptr) {
		CGColorSpaceRelease(color_space);

		CVPixelBufferUnlockBaseAddress(
				pixel_buffer,
				kCVPixelBufferLock_ReadOnly);

		CFRelease(pixel_buffer);
		return nullptr;
	}

	/*
	 * UIKit/CoreGraphics usa origem no canto inferior/esquerdo
	 * para este contexto. Fazemos a transformação para preservar
	 * a orientação visual da imagem.
	 */
	CGContextTranslateCTM(
			context,
			0,
			static_cast<CGFloat>(height));

	CGContextScaleCTM(
			context,
			1.0,
			-1.0);

	CGContextDrawImage(
			context,
			CGRectMake(
					0,
					0,
					static_cast<CGFloat>(width),
					static_cast<CGFloat>(height)),
			image);

	CGContextRelease(context);
	CGColorSpaceRelease(color_space);

	CVPixelBufferUnlockBaseAddress(
			pixel_buffer,
			kCVPixelBufferLock_ReadOnly);

	return pixel_buffer;
}

bool VideoExporter::export_frames(
		const String &frames_directory,
		const String &output_path,
		int fps) {

	if (frames_directory.is_empty()) {
		ERR_PRINT("VideoExporter: frames directory is empty.");
		return false;
	}

	if (output_path.is_empty()) {
		ERR_PRINT("VideoExporter: output path is empty.");
		return false;
	}

	if (fps <= 0) {
		ERR_PRINT("VideoExporter: invalid FPS.");
		return false;
	}

	NSString *frames_path =
			[NSString stringWithUTF8String:
					frames_directory.utf8().get_data()];

	NSString *output_file =
			[NSString stringWithUTF8String:
					output_path.utf8().get_data()];

	if (frames_path == nil || output_file == nil) {
		ERR_PRINT("VideoExporter: invalid UTF-8 path.");
		return false;
	}

	NSFileManager *file_manager =
			[NSFileManager defaultManager];

	BOOL is_directory = NO;

	if (![file_manager fileExistsAtPath:frames_path
							isDirectory:&is_directory] ||
			!is_directory) {

		ERR_PRINT("VideoExporter: frames directory does not exist.");
		return false;
	}

	/*
	 * Procura os arquivos frame_00001.png, frame_00002.png...
	 */
	NSError *directory_error = nil;

	NSArray<NSString *> *all_files =
			[file_manager contentsOfDirectoryAtPath:
							frames_path
											error:&directory_error];

	if (all_files == nil) {
		if (directory_error != nil) {
			NSLog(
					@"VideoExporter: directory error: %@",
					directory_error.localizedDescription);
		}

		ERR_PRINT("VideoExporter: unable to read frames directory.");
		return false;
	}

	NSArray<NSString *> *files =
			[all_files sortedArrayUsingComparator:
					^NSComparisonResult(
							NSString *a,
							NSString *b) {

						return [a compare:b
								options:NSNumericSearch];
					}];

	NSMutableArray<NSString *> *frame_files =
			[NSMutableArray array];

	for (NSString *file in files) {
		if ([[file pathExtension].lowercaseString
				isEqualToString:@"png"]) {

			if ([file hasPrefix:@"frame_"]) {
				[frame_files addObject:file];
			}
		}
	}

	if (frame_files.count == 0) {
		ERR_PRINT("VideoExporter: no PNG frames found.");
		return false;
	}

	/*
	 * Carrega o primeiro frame para determinar
	 * largura e altura do vídeo.
	 */
	NSString *first_frame_path =
			[frames_path stringByAppendingPathComponent:
					frame_files[0]];

	UIImage *first_image =
			[UIImage imageWithContentsOfFile:first_frame_path];

	if (first_image == nil || first_image.CGImage == nil) {
		ERR_PRINT("VideoExporter: unable to load first PNG frame.");
		return false;
	}

	CGImageRef first_cg_image =
			first_image.CGImage;

	size_t width =
			CGImageGetWidth(first_cg_image);

	size_t height =
			CGImageGetHeight(first_cg_image);

	if (width == 0 || height == 0) {
		ERR_PRINT("VideoExporter: invalid frame dimensions.");
		return false;
	}

	/*
	 * H.264 normalmente trabalha melhor com dimensões pares.
	 */
	if ((width % 2) != 0 || (height % 2) != 0) {
		ERR_PRINT(
				"VideoExporter: frame dimensions must be even for H.264.");
		return false;
	}

	/*
	 * Remove um arquivo de saída anterior, se existir.
	 */
	if ([file_manager fileExistsAtPath:output_file]) {
		NSError *remove_error = nil;

		if (![file_manager removeItemAtPath:output_file
									 error:&remove_error]) {

			NSLog(
					@"VideoExporter: unable to remove existing output: %@",
					remove_error.localizedDescription);

			return false;
		}
	}

	/*
	 * Garante que o diretório de saída exista.
	 */
	NSString *output_directory =
			[output_file stringByDeletingLastPathComponent];

	if (output_directory.length > 0 &&
			![file_manager
					createDirectoryAtPath:output_directory
					withIntermediateDirectories:YES
					attributes:nil
					error:nil]) {

		if (![file_manager
				fileExistsAtPath:output_directory]) {

			ERR_PRINT(
					"VideoExporter: unable to create output directory.");
			return false;
		}
	}

	NSURL *output_url =
			[NSURL fileURLWithPath:output_file];

	NSError *writer_error = nil;

	AVAssetWriter *writer =
			[[AVAssetWriter alloc]
					initWithURL:output_url
					fileType:AVFileTypeMPEG4
					error:&writer_error];

	if (writer == nil) {
		if (writer_error != nil) {
			NSLog(
					@"VideoExporter: AVAssetWriter error: %@",
					writer_error.localizedDescription);
		}

		ERR_PRINT("VideoExporter: unable to create AVAssetWriter.");
		return false;
	}

	/*
	 * Configuração H.264.
	 *
	 * 8 Mbps é adequado para os vídeos curtos gerados
	 * pelo Fluxus e pode ser ajustado posteriormente.
	 */
	NSDictionary *compression_properties = @{
		AVVideoAverageBitRateKey : @(8000000),
		AVVideoProfileLevelKey :
				AVVideoProfileLevelH264HighAutoLevel
	};

	NSDictionary *video_settings = @{
		AVVideoCodecKey : AVVideoCodecTypeH264,
		AVVideoWidthKey : @(width),
		AVVideoHeightKey : @(height),
		AVVideoCompressionPropertiesKey :
				compression_properties
	};

	AVAssetWriterInput *video_input =
			[[AVAssetWriterInput alloc]
					initWithMediaType:AVMediaTypeVideo
					outputSettings:video_settings];

	video_input.expectsMediaDataInRealTime = NO;

	if (![writer canAddInput:video_input]) {
		ERR_PRINT(
				"VideoExporter: cannot add video input.");
		return false;
	}

	[writer addInput:video_input];

	if (![writer startWriting]) {
		NSError *error = writer.error;

		if (error != nil) {
			NSLog(
					@"VideoExporter: startWriting error: %@",
					error.localizedDescription);
		}

		ERR_PRINT(
				"VideoExporter: unable to start writing.");
		return false;
	}

	[writer startSessionAtSourceTime:kCMTimeZero];

	/*
	 * Grava os frames.
	 *
	 * Cada frame recebe:
	 *
	 *   frame 0 -> 0/fps
	 *   frame 1 -> 1/fps
	 *   frame 2 -> 2/fps
	 *   ...
	 */
	for (NSUInteger index = 0;
			index < frame_files.count;
			index++) {

		while (!video_input.readyForMoreMediaData) {
			[NSThread sleepForTimeInterval:0.001];

			if (writer.status == AVAssetWriterStatusFailed ||
					writer.status == AVAssetWriterStatusCancelled) {

				break;
			}
		}

		if (writer.status == AVAssetWriterStatusFailed ||
				writer.status == AVAssetWriterStatusCancelled) {

			break;
		}

		NSString *frame_path =
				[frames_path
						stringByAppendingPathComponent:
								frame_files[index]];

		UIImage *image =
				[UIImage imageWithContentsOfFile:frame_path];

		if (image == nil || image.CGImage == nil) {
			NSLog(
					@"VideoExporter: unable to load frame: %@",
					frame_files[index]);

			[video_input markAsFinished];

			if (writer.status == AVAssetWriterStatusWriting) {
				[writer cancelWriting];
			}

			return false;
		}

		CGImageRef image_ref =
				image.CGImage;

		size_t image_width =
				CGImageGetWidth(image_ref);

		size_t image_height =
				CGImageGetHeight(image_ref);

		if (image_width != width ||
				image_height != height) {

			NSLog(
					@"VideoExporter: frame size mismatch: %@",
					frame_files[index]);

			[video_input markAsFinished];

			if (writer.status == AVAssetWriterStatusWriting) {
				[writer cancelWriting];
			}

			return false;
		}

		CVPixelBufferRef pixel_buffer =
				create_pixel_buffer_from_image(
						image_ref,
						width,
						height);

		if (pixel_buffer == nullptr) {
			NSLog(
					@"VideoExporter: unable to create pixel buffer.");
			[video_input markAsFinished];

			if (writer.status == AVAssetWriterStatusWriting) {
				[writer cancelWriting];
			}

			return false;
		}

		CMTime presentation_time =
				CMTimeMake(
						static_cast<int64_t>(index),
						static_cast<int32_t>(fps));

		BOOL appended =
				[video_input appendPixelBuffer:
								pixel_buffer
					withPresentationTime:presentation_time];

		CVPixelBufferRelease(pixel_buffer);

		if (!appended) {
			NSError *error = writer.error;

			if (error != nil) {
				NSLog(
						@"VideoExporter: append error: %@",
						error.localizedDescription);
			}

			[video_input markAsFinished];

			if (writer.status == AVAssetWriterStatusWriting) {
				[writer cancelWriting];
			}

			return false;
		}
	}

	if (writer.status != AVAssetWriterStatusWriting) {
		NSError *error = writer.error;

		if (error != nil) {
			NSLog(
					@"VideoExporter: writer stopped: %@",
					error.localizedDescription);
		}

		return false;
	}

	[video_input markAsFinished];

	/*
	 * finishWriting é assíncrono. Aqui usamos um semaphore
	 * para manter a API C++ síncrona enquanto o Mp4Exporter.gd
	 * ainda trabalha com Thread/call_deferred.
	 */
	dispatch_semaphore_t semaphore =
			dispatch_semaphore_create(0);

	__block BOOL finish_success = NO;

	[writer finishWritingWithCompletionHandler:^{
		finish_success =
				(writer.status == AVAssetWriterStatusCompleted);

		dispatch_semaphore_signal(semaphore);
	}];

	dispatch_semaphore_wait(
			semaphore,
			DISPATCH_TIME_FOREVER);

	if (!finish_success) {
		NSError *error = writer.error;

		if (error != nil) {
			NSLog(
					@"VideoExporter: finishWriting error: %@",
					error.localizedDescription);
		}

		return false;
	}

	/*
	 * Confirma que o arquivo realmente existe.
	 */
	if (![file_manager fileExistsAtPath:output_file]) {
		ERR_PRINT(
				"VideoExporter: MP4 was not created.");
		return false;
	}

	NSDictionary *attributes =
			[file_manager
					attributesOfItemAtPath:output_file
					error:nil];

	unsigned long long file_size =
			[attributes fileSize];

	if (file_size == 0) {
		ERR_PRINT(
				"VideoExporter: generated MP4 is empty.");
		return false;
	}

	NSLog(
			@"VideoExporter: MP4 created successfully: %@ (%llu bytes)",
			output_file,
			file_size);

	return true;
}

/*************************************************************************/
/* Godot iOS plugin initialization                                       */
/*************************************************************************/

void godot_video_exporter_init() {
	GDREGISTER_CLASS(VideoExporter);
}

void godot_video_exporter_deinit() {
}
