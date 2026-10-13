import SwiftUI

struct AboutView: View {
    var body: some View {
        List {
            Section("פרטיות") {
                Text("הסרטונים, המוזיקה והעריכות מעובדים ונשמרים באייפון. אין צורך בחשבון ואין שרת עיבוד, פרסומות או כלי מעקב באפליקציה.")
                Text("סרטון שנמצא רק ב־iCloud עשוי לרדת דרך בורר התמונות של Apple. שיתוף ושמירה לתמונות נעשים רק לפי בחירתכם.")
                Text("מחיקת פרויקט מוחקת את קבציו באפליקציה. עותקים ששמרתם בתמונות או שיתפתם נשארים ביעד שלהם. גיבויי המכשיר עשויים לכלול נתוני אפליקציה בהתאם להגדרות Apple.")
                Link("מדיניות הפרטיות המלאה", destination: URL(string: "https://github.com/erez1980/rk-motion/blob/main/docs/PRIVACY.md")!)
            }.listRowBackground(RK.card)
            Section("עזרה ותמיכה") {
                Text("יכולת העיבוד ברקע תלויה בגרסה, במכשיר ובהרשאות החתימה. iOS יכולה לעצור פעולה; המקור והעריכה נשמרים, ואפשר לנסות שוב.")
                Text("הייצוא הנוכחי הוא SDR בקצב 30 פריימים לשנייה. זיהוי הפעילות מבוסס על תנועה ועוצמת שמע ומציע קטעים לבדיקה.")
                Link("תמיכה ודיווח תקלה", destination: URL(string: "https://github.com/erez1980/rk-motion/issues")!)
                Text("דיווחים ב־GitHub ציבוריים. אל תצרפו סרטונים פרטיים או מידע אישי.").font(.caption)
            }.listRowBackground(RK.card)
            Section("גרסה") {
                Text(verbatim: "RK Motion " + AppVersion.label).monospacedDigit()
            }.listRowBackground(RK.card)
        }
        .font(RK.font(15))
        .scrollContentBackground(.hidden)
        .background(RK.bg.ignoresSafeArea())
        .navigationTitle("אודות ועזרה")
        .navigationBarTitleDisplayMode(.inline)
    }
}
