from sofit import storyboard


def test_scene_cache_changes_with_prompt_style_model_and_reference(tmp_path, monkeypatch):
    generated = []
    monkeypatch.setattr(storyboard, '_gemini_image', lambda parts, aspect: generated.append(parts) or b'image')
    def cover(data, path):
        path.write_bytes(data)
        return path
    monkeypatch.setattr(storyboard, '_save_cover', cover)
    path, sheet = tmp_path / 'scene.png', tmp_path / 'sheet.png'
    sheet.write_bytes(b'first reference')
    storyboard._scene_image('rider', 'comic', sheet, path)
    storyboard._scene_image('rider', 'comic', sheet, path)
    assert len(generated) == 1
    storyboard._scene_image('jumping rider', 'comic', sheet, path)
    storyboard._scene_image('jumping rider', 'photo', sheet, path)
    monkeypatch.setattr(storyboard, 'IMAGE_MODEL', 'other-model')
    storyboard._scene_image('jumping rider', 'photo', sheet, path)
    sheet.write_bytes(b'changed reference')
    storyboard._scene_image('jumping rider', 'photo', sheet, path)
    assert len(generated) == 5
