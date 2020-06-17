#!usr/bin/env ruby
require 'rubygems'
require 'bundler/setup'
require 'mini_magick' # imagemagick also required as dependency, not a gem
require 'streamio-ffmpeg' # Wrapper for ffmpeg, try to remove later stackoverflow.com/questions/54295358 talks about pipe to save from writing to disk

INPUT_VIDEO = 'Untitled 67.avi'.freeze
OUTPUT_VIDEO = 'output.avi'.freeze
START_TIME = Process.clock_gettime(Process::CLOCK_MONOTONIC)
MAX_PROCESSES = Etc.nprocessors # Credit for multithreading to stackoverflow.com/questions/35387024
MiniMagick.configure do |config| # Stops error when doing mean filtering, nonzero exit code being returned when executed
  config.whiny = false
end

# Convert the video into a series of screenshots
# FIXME: As frame_rate isn't actually 30, duration * fps > num_frames. FFmpeg still works even if it's too large
puts 'On step 1, extracting the images'
video = FFMPEG::Movie.new(INPUT_VIDEO)
video.screenshot('screenshots/screenshot_%3d.png', { vframes: (video.duration * video.frame_rate).to_i, frame_rate: video.frame_rate }, { validate: false }) { |progress| puts "\tStep 1: #{(progress * 100).truncate(1)}%" } # output every frame as a screenshot to disk

# Process the images
puts "\nOn step 2, processing the images"
frames = Dir.entries('screenshots').reject { |f| File.directory? f } # Get array of files (and only files)

count = 0 # TODO: remove count, replace with location of elements.first in frames
frames.each_slice(MAX_PROCESSES) do |elements|
  elements.each do |screenshot|
    fork {
      frame = MiniMagick::Image.open('screenshots/' + screenshot)
      # Square color values to improve contrast, get_pixels returns array of rows, containing array
      colors = frame.get_pixels.flatten
      colors.map! do |color|
        color**2 / 255
      end
      blob = colors.pack('C*') # Recreate the original image, credit to stackoverflow.com/questions/53764046
      frame = MiniMagick::Image.import_pixels(blob, frame.width, frame.height, 8, 'rgb')
      # Noise correction and thresholding
      frame = frame.statistic('mean', '3x3')
      frame = frame.threshold('40%')
      frame = frame.statistic('median', '6x6') # median filter removes speckles while keeping particles intact
      frame.write('edits/' + screenshot)
    }
  end
  Process.waitall
  count += elements.size
  puts "\tStep 2: #{((count / frames.size.to_f) * 100).truncate(1)}%"
end

# Convert procesed images to video
puts "\nOn step 3, exporting the video"
puts "Num frames: #{frames.size}"
puts "Put video length: #{video.duration}"
%x(ffmpeg -framerate #{frames.size / video.duration} -i edits/screenshot_%3d.png -pix_fmt yuv420p '#{OUTPUT_VIDEO}')

# Delete the screenshots we've taken. Otherwise it'll mess up the fps in later videos
# TODO: Option to keep for later, warning them to delete afterwards
Dir.each_child('screenshots') { |x| File.delete('screenshots/' + x) }
Dir.each_child('edits') { |x| File.delete('edits/' + x) }

# Output end time
END_TIME = Process.clock_gettime(Process::CLOCK_MONOTONIC)
puts "This program ran for #{((END_TIME - START_TIME) / 60).truncate(1)} minutes"
