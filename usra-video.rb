#!usr/bin/env ruby
require 'rubygems'
require 'bundler/setup'
require 'mini_magick' # imagemagick also required as dependency, not a gem
require 'streamio-ffmpeg' # Wrapper for ffmpeg, try to remove later stackoverflow.com/questions/54295358

INPUT_VIDEO = 'Untitled 67.avi'.freeze
OUTPUT_VIDEO = 'output.avi'.freeze
INPUT_FRAME_DIR = 'input_frames/'.freeze
OUTPUT_FRAME_DIR = 'output_frames/'.freeze
THRESHOLD_PERCENT = '40%'.freeze
MAX_PROCESSES = Etc.nprocessors # Credit for multithreading to stackoverflow.com/questions/35387024
MiniMagick.configure do |config| # Stops error when doing mean filtering, nonzero exit code being returned when executed
  config.whiny = false
end

# If INPUT and OUTPUT dirs don't already exist, create them
Dir.mkdir(INPUT_FRAME_DIR) unless Dir.exist?(INPUT_FRAME_DIR)
Dir.mkdir(OUTPUT_FRAME_DIR) unless Dir.exist?(OUTPUT_FRAME_DIR)

# Delete the screenshots we've taken. Otherwise it'll mess up the fps in later videos
Dir.each_child(INPUT_FRAME_DIR) { |x| File.delete(INPUT_FRAME_DIR + x) }
Dir.each_child(OUTPUT_FRAME_DIR) { |x| File.delete(OUTPUT_FRAME_DIR + x) }

# Convert the video into a series of screenshots
# FIXME: As frame_rate isn't actually 30, duration * fps > num_frames. FFmpeg still works even if it's too large
puts 'On step 1, extracting the images'
video = FFMPEG::Movie.new(INPUT_VIDEO)
video.screenshot(INPUT_FRAME_DIR + 'frame_%3d.png',
                 { vframes: (video.duration * video.frame_rate).to_i, frame_rate: video.frame_rate },
                 { validate: false }) { |progress| puts "\tStep 1: #{(progress * 100).truncate(1)}%" }

# Process the images
puts "\nOn step 2, processing the images"
frames = Dir.entries(INPUT_FRAME_DIR).reject { |f| File.directory? f } # Get array of files (and only files)
frames.each_slice(MAX_PROCESSES).with_index(1) do |elements, i|
  elements.each do |frame|
    fork do
      image = MiniMagick::Image.open(INPUT_FRAME_DIR + frame)
      # Square color values to improve contrast, get_pixels returns array of rows, containing array
      colors = image.get_pixels.flatten
      colors.map! { |color| color**2 / 255 }
      blob = colors.pack('C*') # Recreate the original image, credit to stackoverflow.com/questions/53764046
      image = MiniMagick::Image.import_pixels(blob, image.width, image.height, 8, 'rgb')
      # Noise correction and thresholding
      image = image.statistic('mean', '3x3')
      image = image.threshold(THRESHOLD_PERCENT)
      image = image.statistic('median', '6x6') # median filter removes speckles while keeping particles intact
      image.write(OUTPUT_FRAME_DIR + frame)
    end
  end
  Process.waitall
  puts "\tStep 2: #{(i * elements.size / frames.size.to_f * 100).truncate(1)}%"
end

# Convert procesed images to video
puts "\nOn step 3, exporting the video"
average_framerate = frames.size / video.duration
`ffmpeg -framerate #{average_framerate} -i #{OUTPUT_FRAME_DIR + 'frame_%3d.png'} -pix_fmt yuv420p '#{OUTPUT_VIDEO}'`
