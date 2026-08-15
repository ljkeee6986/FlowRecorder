import { Navigate, Route, Routes } from "react-router-dom";
import { TeacherPage } from "./TeacherPage";
import { ViewerPage } from "./ViewerPage";

export function App() {
  return (
    <Routes>
      <Route path="/teacher" element={<TeacherPage />} />
      <Route path="/live/:shareCode" element={<ViewerPage />} />
      <Route path="*" element={<Navigate to="/teacher" replace />} />
    </Routes>
  );
}
