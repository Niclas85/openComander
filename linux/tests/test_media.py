import shutil
import subprocess
import pytest
from PySide6.QtCore import QSize
from PySide6.QtGui import QImage, QColor
from opencommander.media import read_image, thumbnail, media_kind


def test_thumbnail_dimensions_and_corrupt_file(tmp_path):
    path = tmp_path / 'wide.PNG'
    image = QImage(1200, 600, QImage.Format_RGB32)
    image.fill(QColor('green'))
    image.save(str(path))
    result = thumbnail(path, 'image')
    assert result.width() == 96 and result.height() == 48
    assert media_kind(path) == 'image'
    assert media_kind('MOVIE.MP4') == 'video'
    assert media_kind('music.flac') == 'audio'
    path.write_bytes(b'bad image')
    with pytest.raises(ValueError):
        read_image(path, QSize(96, 64))


@pytest.mark.skipif(not shutil.which('ffmpeg'), reason='ffmpeg is optional for video thumbnails')
def test_video_thumbnail(tmp_path):
    path = tmp_path / 'sample.mp4'
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=blue:s=160x90:d=0.2',
                    '-c:v', 'mpeg4', str(path)], check=True, timeout=10)
    result = thumbnail(path, 'video')
    assert not result.isNull()
    assert result.width() <= 96 and result.height() <= 64
