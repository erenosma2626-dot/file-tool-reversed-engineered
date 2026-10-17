import Foundation
import CoreGraphics

enum PPTXWriterError: Error {
    case noImages
    case invalidSlideSize
    case unsupportedImageFormat(Int)
}

enum PPTXWriter {

    private static let nsA = "http://schemas.openxmlformats.org/drawingml/2006/main"
    private static let nsR = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let nsP = "http://schemas.openxmlformats.org/presentationml/2006/main"
    private static let relNS = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let relTypeBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"

    /// One slide per image, each image filling the slide. `slideSize` is in points.
    /// Images must be PNG or JPEG data.
    static func write(images: [Data], slideSize: CGSize, to url: URL) throws {
        guard !images.isEmpty else { throw PPTXWriterError.noImages }
        guard slideSize.width > 0, slideSize.height > 0 else { throw PPTXWriterError.invalidSlideSize }

        var extensions: [String] = []
        for (index, data) in images.enumerated() {
            guard let ext = imageExtension(for: data) else {
                throw PPTXWriterError.unsupportedImageFormat(index)
            }
            extensions.append(ext)
        }

        let cx = emu(slideSize.width)
        let cy = emu(slideSize.height)
        let count = images.count
        let now = isoTimestamp(Date())

        let zip = ZipWriter()
        zip.add(path: "[Content_Types].xml", string: contentTypesXML(count: count))
        zip.add(path: "_rels/.rels", string: rootRelsXML())
        zip.add(path: "docProps/core.xml", string: coreXML(now: now))
        zip.add(path: "docProps/app.xml", string: appXML(slideCount: count))
        zip.add(path: "ppt/presentation.xml", string: presentationXML(count: count, cx: cx, cy: cy))
        zip.add(path: "ppt/_rels/presentation.xml.rels", string: presentationRelsXML(count: count))
        zip.add(path: "ppt/slideMasters/slideMaster1.xml", string: slideMasterXML())
        zip.add(path: "ppt/slideMasters/_rels/slideMaster1.xml.rels", string: slideMasterRelsXML())
        zip.add(path: "ppt/slideLayouts/slideLayout1.xml", string: slideLayoutXML())
        zip.add(path: "ppt/slideLayouts/_rels/slideLayout1.xml.rels", string: slideLayoutRelsXML())
        zip.add(path: "ppt/theme/theme1.xml", string: themeXML())

        for index in 0..<count {
            let n = index + 1
            let ext = extensions[index]
            zip.add(path: "ppt/slides/slide\(n).xml", string: slideXML(cx: cx, cy: cy))
            zip.add(path: "ppt/slides/_rels/slide\(n).xml.rels", string: slideRelsXML(imageFileName: "image\(n).\(ext)"))
            zip.add(path: "ppt/media/image\(n).\(ext)", data: images[index], compress: false)
        }

        try zip.write(to: url)
    }

    // MARK: - Helpers

    private static func emu(_ points: CGFloat) -> Int {
        return Int((points * 12700).rounded())
    }

    private static func imageExtension(for data: Data) -> String? {
        let bytes = [UInt8](data.prefix(4))
        if bytes.count >= 4 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
            return "png"
        }
        if bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8 {
            return "jpeg"
        }
        return nil
    }

    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let utc: TimeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        formatter.timeZone = utc
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }

    private static func xmlHeader() -> String {
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    }

    private static func namespaceDecls() -> String {
        return "xmlns:a=\"\(nsA)\" xmlns:r=\"\(nsR)\" xmlns:p=\"\(nsP)\""
    }

    private static let emptyGroupProps = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>"
        + "<p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"

    // MARK: - Package-level parts

    private static func contentTypesXML(count: Int) -> String {
        var s = xmlHeader()
        s += "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        s += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        s += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        s += "<Default Extension=\"png\" ContentType=\"image/png\"/>"
        s += "<Default Extension=\"jpeg\" ContentType=\"image/jpeg\"/>"
        s += "<Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/>"
        for index in 0..<count {
            s += "<Override PartName=\"/ppt/slides/slide\(index + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
        }
        s += "<Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/>"
        s += "<Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/>"
        s += "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>"
        s += "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
        s += "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"
        s += "</Types>"
        return s
    }

    private static func rootRelsXML() -> String {
        var s = xmlHeader()
        s += "<Relationships xmlns=\"\(relNS)\">"
        s += "<Relationship Id=\"rId1\" Type=\"\(relTypeBase)officeDocument\" Target=\"ppt/presentation.xml\"/>"
        s += "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>"
        s += "<Relationship Id=\"rId3\" Type=\"\(relTypeBase)extended-properties\" Target=\"docProps/app.xml\"/>"
        s += "</Relationships>"
        return s
    }

    private static func coreXML(now: String) -> String {
        var s = xmlHeader()
        s += "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\""
        s += " xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\""
        s += " xmlns:dcmitype=\"http://purl.org/dc/dcmitype/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
        s += "<dc:title>Presentation</dc:title>"
        s += "<dc:creator>Facet</dc:creator>"
        s += "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(now)</dcterms:created>"
        s += "<dcterms:modified xsi:type=\"dcterms:W3CDTF\">\(now)</dcterms:modified>"
        s += "</cp:coreProperties>"
        return s
    }

    private static func appXML(slideCount: Int) -> String {
        var s = xmlHeader()
        s += "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\""
        s += " xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\">"
        s += "<Application>Facet</Application>"
        s += "<Slides>\(slideCount)</Slides>"
        s += "</Properties>"
        return s
    }

    private static func presentationXML(count: Int, cx: Int, cy: Int) -> String {
        var s = xmlHeader()
        s += "<p:presentation \(namespaceDecls()) saveSubsetFonts=\"1\">"
        s += "<p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst>"
        s += "<p:sldIdLst>"
        for index in 0..<count {
            // Slide relationships start at rId3 (rId1 = master, rId2 = theme).
            s += "<p:sldId id=\"\(256 + index)\" r:id=\"rId\(index + 3)\"/>"
        }
        s += "</p:sldIdLst>"
        s += "<p:sldSz cx=\"\(cx)\" cy=\"\(cy)\"/>"
        s += "<p:notesSz cx=\"6858000\" cy=\"9144000\"/>"
        s += "</p:presentation>"
        return s
    }

    private static func presentationRelsXML(count: Int) -> String {
        var s = xmlHeader()
        s += "<Relationships xmlns=\"\(relNS)\">"
        s += "<Relationship Id=\"rId1\" Type=\"\(relTypeBase)slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>"
        s += "<Relationship Id=\"rId2\" Type=\"\(relTypeBase)theme\" Target=\"theme/theme1.xml\"/>"
        for index in 0..<count {
            s += "<Relationship Id=\"rId\(index + 3)\" Type=\"\(relTypeBase)slide\" Target=\"slides/slide\(index + 1).xml\"/>"
        }
        s += "</Relationships>"
        return s
    }

    // MARK: - Master, layout, theme

    private static func slideMasterXML() -> String {
        var s = xmlHeader()
        s += "<p:sldMaster \(namespaceDecls())>"
        s += "<p:cSld>"
        s += "<p:bg><p:bgRef idx=\"1001\"><a:schemeClr val=\"bg1\"/></p:bgRef></p:bg>"
        s += "<p:spTree>\(emptyGroupProps)</p:spTree>"
        s += "</p:cSld>"
        s += "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
        s += "<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst>"
        s += "</p:sldMaster>"
        return s
    }

    private static func slideMasterRelsXML() -> String {
        var s = xmlHeader()
        s += "<Relationships xmlns=\"\(relNS)\">"
        s += "<Relationship Id=\"rId1\" Type=\"\(relTypeBase)slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>"
        s += "<Relationship Id=\"rId2\" Type=\"\(relTypeBase)theme\" Target=\"../theme/theme1.xml\"/>"
        s += "</Relationships>"
        return s
    }

    private static func slideLayoutXML() -> String {
        var s = xmlHeader()
        s += "<p:sldLayout \(namespaceDecls()) type=\"blank\" preserve=\"1\">"
        s += "<p:cSld name=\"Blank\">"
        s += "<p:spTree>\(emptyGroupProps)</p:spTree>"
        s += "</p:cSld>"
        s += "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>"
        s += "</p:sldLayout>"
        return s
    }

    private static func slideLayoutRelsXML() -> String {
        var s = xmlHeader()
        s += "<Relationships xmlns=\"\(relNS)\">"
        s += "<Relationship Id=\"rId1\" Type=\"\(relTypeBase)slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/>"
        s += "</Relationships>"
        return s
    }

    private static func themeXML() -> String {
        var s = xmlHeader()
        s += "<a:theme xmlns:a=\"\(nsA)\" name=\"Facet\">"
        s += "<a:themeElements>"

        s += "<a:clrScheme name=\"Facet\">"
        s += "<a:dk1><a:sysClr val=\"windowText\" lastClr=\"000000\"/></a:dk1>"
        s += "<a:lt1><a:sysClr val=\"window\" lastClr=\"FFFFFF\"/></a:lt1>"
        s += "<a:dk2><a:srgbClr val=\"1F497D\"/></a:dk2>"
        s += "<a:lt2><a:srgbClr val=\"EEECE1\"/></a:lt2>"
        s += "<a:accent1><a:srgbClr val=\"4F81BD\"/></a:accent1>"
        s += "<a:accent2><a:srgbClr val=\"C0504D\"/></a:accent2>"
        s += "<a:accent3><a:srgbClr val=\"9BBB59\"/></a:accent3>"
        s += "<a:accent4><a:srgbClr val=\"8064A2\"/></a:accent4>"
        s += "<a:accent5><a:srgbClr val=\"4BACC6\"/></a:accent5>"
        s += "<a:accent6><a:srgbClr val=\"F79646\"/></a:accent6>"
        s += "<a:hlink><a:srgbClr val=\"0000FF\"/></a:hlink>"
        s += "<a:folHlink><a:srgbClr val=\"800080\"/></a:folHlink>"
        s += "</a:clrScheme>"

        s += "<a:fontScheme name=\"Facet\">"
        s += "<a:majorFont><a:latin typeface=\"Calibri\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont>"
        s += "<a:minorFont><a:latin typeface=\"Calibri\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont>"
        s += "</a:fontScheme>"

        s += "<a:fmtScheme name=\"Facet\">"
        s += "<a:fillStyleLst>"
        s += "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        s += "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        s += "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        s += "</a:fillStyleLst>"
        s += "<a:lnStyleLst>"
        s += "<a:ln w=\"9525\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:prstDash val=\"solid\"/></a:ln>"
        s += "<a:ln w=\"25400\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:prstDash val=\"solid\"/></a:ln>"
        s += "<a:ln w=\"38100\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:prstDash val=\"solid\"/></a:ln>"
        s += "</a:lnStyleLst>"
        s += "<a:effectStyleLst>"
        s += "<a:effectStyle><a:effectLst/></a:effectStyle>"
        s += "<a:effectStyle><a:effectLst/></a:effectStyle>"
        s += "<a:effectStyle><a:effectLst/></a:effectStyle>"
        s += "</a:effectStyleLst>"
        s += "<a:bgFillStyleLst>"
        s += "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        s += "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        s += "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        s += "</a:bgFillStyleLst>"
        s += "</a:fmtScheme>"

        s += "</a:themeElements>"
        s += "<a:objectDefaults/>"
        s += "<a:extraClrSchemeLst/>"
        s += "</a:theme>"
        return s
    }

    // MARK: - Slides

    private static func slideXML(cx: Int, cy: Int) -> String {
        var s = xmlHeader()
        s += "<p:sld \(namespaceDecls())>"
        s += "<p:cSld><p:spTree>"
        s += emptyGroupProps
        s += "<p:pic>"
        s += "<p:nvPicPr><p:cNvPr id=\"2\" name=\"Slide Image\"/><p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>"
        s += "<p:blipFill><a:blip r:embed=\"rId2\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>"
        s += "<p:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr>"
        s += "</p:pic>"
        s += "</p:spTree></p:cSld>"
        s += "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>"
        s += "</p:sld>"
        return s
    }

    private static func slideRelsXML(imageFileName: String) -> String {
        var s = xmlHeader()
        s += "<Relationships xmlns=\"\(relNS)\">"
        s += "<Relationship Id=\"rId1\" Type=\"\(relTypeBase)slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>"
        s += "<Relationship Id=\"rId2\" Type=\"\(relTypeBase)image\" Target=\"../media/\(imageFileName)\"/>"
        s += "</Relationships>"
        return s
    }
}
